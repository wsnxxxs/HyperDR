#include "../../../tests/support/temp_directory.hpp"
// VideoToolbox HEVC: colour conversion and tiling, the encoder's sequence
// contract (one IDR per tile, shared parameter sets, clean samples), round-trip
// quality, the capabilities probe and its cache. Exits 77 (skipped) only when
// the machine has no HEVC encoder at all.

#include "hevc/hevc.hpp"
#include "hevc_probe_policy.hpp"
#include "hevc/testing.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/transfer.hpp"

#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <pthread.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace hevc = hyperdr::codec::hevc;

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

template <class Fn>
bool throws_as(Fn&& fn, const auto& probe_type) {
  using Expected = std::remove_cvref_t<decltype(probe_type)>;
  try {
    fn();
  } catch (const Expected&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

hevc::RgbRowReader solid(float r, float g, float b) {
  return [=](std::uint32_t, std::uint32_t, std::uint32_t count, float* rgb) {
    for (std::uint32_t i = 0; i < count; ++i) {
      rgb[i * 3] = r;
      rgb[i * 3 + 1] = g;
      rgb[i * 3 + 2] = b;
    }
  };
}

void check_solid(float r, float g, float b, int matrix, int depth, unsigned y, unsigned cb,
                 unsigned cr, const std::string& name) {
  const auto tiles = hevc::tiles_from_rgb(4, 4, solid(r, g, b), matrix, depth, false);
  require(tiles.size() == 1, name + ": one tile");
  require(tiles[0].luma_at(0, 0) == y && tiles[0].luma_at(511, 511) == y,
          name + ": Y " + std::to_string(tiles[0].luma_at(0, 0)));
  require(tiles[0].cb_at(0, 0) == cb && tiles[0].cb_at(255, 255) == cb,
          name + ": Cb " + std::to_string(tiles[0].cb_at(0, 0)));
  require(tiles[0].cr_at(0, 0) == cr && tiles[0].cr_at(255, 255) == cr,
          name + ": Cr " + std::to_string(tiles[0].cr_at(0, 0)));
}

void test_conversion() {
  // Full range: white and black at the extremes, chroma centred.
  check_solid(1, 1, 1, 1, 8, 255, 128, 128, "8-bit white");
  check_solid(0, 0, 0, 1, 8, 0, 128, 128, "8-bit black");
  check_solid(1, 1, 1, 9, 10, 1023, 512, 512, "10-bit white");
  // BT.709 red: Y = 0.2126, Cb = -0.2126 / 1.8556, Cr = +0.5 (clamped at the top).
  check_solid(1, 0, 0, 1, 8, 54, 99, 255, "BT.709 red");
  // BT.2020 red: Y = 0.2627, Cb = -0.2627 / 1.8814.
  check_solid(1, 0, 0, 9, 10, 269, 369, 1023, "BT.2020 red");
  // Out of range and NaN clamp; NaN is black rather than undefined.
  const float nan = std::numeric_limits<float>::quiet_NaN();
  check_solid(nan, nan, nan, 1, 8, 0, 128, 128, "NaN");
  check_solid(2, 2, 2, 1, 8, 255, 128, 128, "above white");

  // P010 layout: the code in the high ten bits, little-endian.
  const auto white = hevc::tiles_from_rgb(2, 2, solid(1, 1, 1), 9, 10, false);
  require(white[0].luma[0] == 0xC0 && white[0].luma[1] == 0xFF, "P010 white bytes");
  require(white[0].chroma[0] == 0x00 && white[0].chroma[1] == 0x80, "P010 neutral chroma bytes");

  // Chroma is the mean of the 2x2 block: red, green / blue, white.
  const hevc::RgbRowReader quad = [](std::uint32_t y, std::uint32_t x0, std::uint32_t count,
                                     float* rgb) {
    static constexpr float colours[2][2][3] = {{{1, 0, 0}, {0, 1, 0}}, {{0, 0, 1}, {1, 1, 1}}};
    for (std::uint32_t i = 0; i < count; ++i) {
      const auto x = x0 + i;
      for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = colours[y & 1][x & 1][c];
    }
  };
  const auto quads = hevc::tiles_from_rgb(2, 2, quad, 1, 8, false);
  double cb = 0, cr = 0;
  static constexpr float colours[4][3] = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}};
  for (const auto& c : colours) {
    const double luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    cb += (c[2] - luma) / (2 * (1 - 0.0722)) / 4;
    cr += (c[0] - luma) / (2 * (1 - 0.2126)) / 4;
  }
  const auto expected_cb = static_cast<unsigned>(std::lround(128 + cb * 255));
  const auto expected_cr = static_cast<unsigned>(std::lround(128 + cr * 255));
  require(quads[0].cb_at(0, 0) == expected_cb && quads[0].cr_at(0, 0) == expected_cr,
          "2x2 chroma mean");
  require(quads[0].luma_at(0, 0) == 54 && quads[0].luma_at(1, 1) == 255, "per-pixel luma");

  // Odd sizes: 515 x 3 is two tiles; the reader sees only picture pixels, and
  // the padding repeats the last column and row.
  std::mutex calls_mutex;
  std::vector<std::array<std::uint32_t, 3>> calls;
  const hevc::RgbRowReader ramp = [&](std::uint32_t y, std::uint32_t x0, std::uint32_t count,
                                      float* rgb) {
    {
      std::lock_guard lock(calls_mutex);
      calls.push_back({y, x0, count});
    }
    for (std::uint32_t i = 0; i < count; ++i) {
      const float v = static_cast<float>((x0 + i) % 256) / 255.0F * (y == 2 ? 0.5F : 1.0F);
      rgb[i * 3] = rgb[i * 3 + 1] = rgb[i * 3 + 2] = v;
    }
  };
  const auto odd = hevc::tiles_from_rgb(515, 3, ramp, 1, 8, false);
  require(odd.size() == 2, "515 x 3 is two tiles");
  for (const auto& call : calls) {
    require(call[0] < 3, "reader row inside the picture");
    require((call[1] == 0 && call[2] == 512) || (call[1] == 512 && call[2] == 3),
            "reader span inside the picture");
  }
  const unsigned last = odd[1].luma_at(2, 0);  // x = 514
  require(last == 2, "last column value");
  require(odd[1].luma_at(3, 0) == last && odd[1].luma_at(511, 0) == last, "column padding");
  require(odd[1].luma_at(2, 3) == odd[1].luma_at(2, 2) &&
              odd[1].luma_at(2, 511) == odd[1].luma_at(2, 2),
          "row padding");
  require(odd[1].luma_at(2, 2) == 1, "last row value");
  // The last chroma row averages picture row 2 with its own repeat.
  require(odd[1].cb_at(1, 1) == 128 && odd[1].cb_at(255, 255) == 128, "grey padding chroma");

  // Dither is keyed on picture coordinates: the same tile either way.
  const auto a = hevc::tiles_from_rgb(600, 20, ramp, 1, 10, true);
  hevc::YuvTile b = hevc::make_tile(10);
  hevc::rgb_tile(hevc::tile_grid(600, 20), 1, ramp, 1, true, b);
  require(a[1].luma == b.luma && a[1].chroma == b.chroma, "per-tile conversion is stable");

  // Gain map: luma only, neutral chroma, no dither.
  const auto gain = hevc::tiles_from_luma(
      700, 700,
      [](std::uint32_t, std::uint32_t x0, std::uint32_t count, float* out) {
        for (std::uint32_t i = 0; i < count; ++i) out[i] = (x0 + i) < 600 ? 0.5F : 1.0F;
      },
      8);
  require(gain.size() == 4, "gain map tiles");
  require(gain[0].luma_at(0, 0) == 128 && gain[1].luma_at(100, 0) == 255 &&
              gain[3].luma_at(511, 511) == 255,
          "gain map luma");
  require(gain[3].cb_at(0, 0) == 128 && gain[3].cr_at(255, 255) == 128, "gain map chroma");

  require(throws_as([] { (void)hevc::tile_grid(0, 4); }, std::invalid_argument("")),
          "empty picture rejected");
  require(throws_as([] { (void)hevc::make_tile(12); }, std::invalid_argument("")),
          "12-bit rejected");
  require(throws_as([] { (void)hevc::tiles_from_rgb(4, 4, solid(0, 0, 0), 5, 8, false); },
                    std::invalid_argument("")),
          "unknown matrix rejected");
}

void test_quality_map() {
  require(hevc::vt_quality(-5) == 0.0F && hevc::vt_quality(0) == 0.0F, "quality floor");
  require(hevc::vt_quality(100) == 1.0F && hevc::vt_quality(250) == 1.0F, "quality ceiling");
  float previous = -1.0F;
  for (int q = 0; q <= 100; ++q) {
    require(hevc::vt_quality(q) > previous, "quality map is increasing");
    previous = hevc::vt_quality(q);
  }
}

// A photograph-like test card: smooth colour fields and soft edges.
hevc::RgbRowReader card() {
  return [](std::uint32_t y, std::uint32_t x0, std::uint32_t count, float* rgb) {
    for (std::uint32_t i = 0; i < count; ++i) {
      const double x = x0 + i;
      const double disc = std::hypot(x - 600.0, y - 380.0) < 170.0 ? 0.25 : 0.0;
      rgb[i * 3] = static_cast<float>(0.45 + 0.35 * std::sin(x / 97.0) * std::cos(y / 71.0) + disc);
      rgb[i * 3 + 1] = static_cast<float>(0.35 + 0.3 * (x + y) / 1800.0 + 0.1 * std::sin(y / 40.0));
      rgb[i * 3 + 2] = static_cast<float>(0.55 - 0.25 * std::cos((x - y) / 130.0) - disc * 0.5);
    }
  };
}

std::vector<std::vector<std::uint8_t>> split_nal_units(const std::vector<std::uint8_t>& sample) {
  std::vector<std::vector<std::uint8_t>> units;
  std::size_t at = 0;
  while (at < sample.size()) {
    require(sample.size() - at >= 4, "sample ends inside a length");
    const std::size_t length = (std::size_t{sample[at]} << 24) | (std::size_t{sample[at + 1]} << 16) |
                               (std::size_t{sample[at + 2]} << 8) | sample[at + 3];
    at += 4;
    require(length >= 2 && length <= sample.size() - at, "NAL length inside the sample");
    units.emplace_back(sample.begin() + static_cast<std::ptrdiff_t>(at),
                       sample.begin() + static_cast<std::ptrdiff_t>(at + length));
    at += length;
  }
  return units;
}

int nal_type(const std::vector<std::uint8_t>& nal) { return (nal[0] >> 1) & 0x3F; }

double luma_psnr(const std::vector<hevc::YuvTile>& source, const std::vector<hevc::YuvTile>& decoded,
                 const hevc::TileGrid& grid) {
  const double max_code = (1U << static_cast<unsigned>(source[0].bit_depth)) - 1U;
  double squared = 0.0;
  std::size_t samples = 0;
  for (std::size_t t = 0; t < grid.count(); ++t) {
    const std::uint32_t x0 = static_cast<std::uint32_t>(t % grid.columns) * hevc::kTileSize;
    const std::uint32_t y0 = static_cast<std::uint32_t>(t / grid.columns) * hevc::kTileSize;
    for (std::uint32_t y = 0; y < hevc::kTileSize && y0 + y < grid.height; ++y) {
      for (std::uint32_t x = 0; x < hevc::kTileSize && x0 + x < grid.width; ++x) {
        const double d = static_cast<double>(source[t].luma_at(x, y)) - decoded[t].luma_at(x, y);
        squared += d * d;
        ++samples;
      }
    }
  }
  const double mse = squared / static_cast<double>(samples);
  return mse == 0.0 ? 99.0 : 10.0 * std::log10(max_code * max_code / mse);
}

void test_sequence(int depth) {
  const std::string name = std::to_string(depth) + "-bit";
  const auto grid = hevc::tile_grid(1024, 768);
  require(grid.columns == 2 && grid.rows == 2, "1024 x 768 is 2 x 2 tiles");
  const int matrix = depth > 8 ? 9 : 1;
  const auto tiles = hevc::tiles_from_rgb(1024, 768, card(), matrix, depth, true);

  hevc::EncodeParams params;
  params.quality = 90;
  params.main10 = depth > 8;
  params.color = depth > 8 ? hevc::ColorDescription{9, 16, 9} : hevc::ColorDescription{12, 13, 1};
  const auto sequence = hevc::encode(tiles, params);

  require(sequence.samples.size() == 4, name + ": four samples");
  require(!sequence.vps.empty() && nal_type(sequence.vps) == 32, name + ": VPS");
  require(!sequence.sps.empty() && nal_type(sequence.sps) == 33, name + ": SPS");
  require(!sequence.pps.empty() && nal_type(sequence.pps) == 34, name + ": PPS");
  require((sequence.sps[3] & 0x1F) == (depth > 8 ? 2 : 1), name + ": SPS profile");
  for (const auto& sample : sequence.samples) {
    const auto units = split_nal_units(sample);
    require(!units.empty(), name + ": sample has NAL units");
    bool slice = false;
    for (const auto& unit : units) {
      const int type = nal_type(unit);
      require(type != 35 && type != 39 && type != 40, name + ": no AUD or SEI");
      require(type < 48, name + ": no UNSPEC NALs");
      require(type < 32 || type > 34, name + ": no in-band parameter sets");
      if (type < 32) {
        require(type == 19 || type == 20, name + ": every slice is IDR");
        slice = true;
      }
    }
    require(slice, name + ": sample has a slice");
  }

  // The bitstream's VUI agrees with what the container will say in nclx.
  const auto vui = hevc::bitstream_color(sequence);
  require(vui.full_range, name + ": VUI full range");
  require(vui.color.primaries == params.color.primaries &&
              vui.color.transfer == params.color.transfer &&
              vui.color.matrix == params.color.matrix,
          name + ": VUI colour " + std::to_string(vui.color.primaries) + "/" +
              std::to_string(vui.color.transfer) + "/" + std::to_string(vui.color.matrix));

  // All four pictures decode with the one set of parameter sets.
  const auto decoded = hevc::decode(sequence, depth);
  require(decoded.size() == 4, name + ": four decoded tiles");
  const double psnr = luma_psnr(tiles, decoded, grid);
  std::size_t bytes = 0;
  for (const auto& sample : sequence.samples) bytes += sample.size();
  std::cout << name << ": " << bytes << " bytes, Y-PSNR " << psnr << " dB\n";
  require(psnr >= 40.0, name + ": Y-PSNR " + std::to_string(psnr) + " dB below 40");

  const auto again = hevc::encode(tiles, params);
  std::cout << name << ": repeated encode is "
            << (again.samples == sequence.samples && again.sps == sequence.sps ? "identical"
                                                                               : "different")
            << "\n";

  hevc::EncodeParams fast = params;
  fast.prefer_speed = true;
  require(hevc::encode(tiles, fast).samples.size() == 4, name + ": speed preference encodes");
}

void test_cancelled_first_probe(const std::filesystem::path& directory) {
  hevc::invalidate_encoder_caps();
  hyperdr::CancelToken token;
  token.request();
  {
    hyperdr::CancelScope scope(&token);
    require(throws_as([&] { (void)hevc::encoder_caps(directory); }, hyperdr::Cancelled()),
            "a cancelled first probe must propagate Cancelled");
  }
  require(!std::filesystem::exists(directory / ".hevc-encoder-caps.json"),
          "a cancelled probe must not publish a disk result");
  // main() calls encoder_caps next, without invalidation: this must really
  // probe again rather than returning a remembered cancellation failure.
}

void test_producer_tile_validation(const std::filesystem::path& directory) {
  using Corrupt = void (*)(hevc::YuvTile&);
  const Corrupt corruptions[] = {
      [](hevc::YuvTile& tile) { tile.luma = std::vector<std::uint8_t>(1, 123); },
      [](hevc::YuvTile& tile) { tile.chroma = std::vector<std::uint8_t>(1, 123); },
      [](hevc::YuvTile& tile) { tile.luma.push_back(0); },
      [](hevc::YuvTile& tile) { tile.chroma.push_back(0); },
      [](hevc::YuvTile& tile) { tile.bit_depth = tile.bit_depth == 8 ? 10 : 8; }};
  for (const int depth : {8, 10}) {
    hevc::EncodeParams params;
    params.main10 = depth > 8;
    for (const auto corrupt : corruptions) {
      auto tile = hevc::make_tile(depth);
      corrupt(tile);
      require(throws_as([&] { (void)hevc::encode(std::span<const hevc::YuvTile>(&tile, 1), params); },
                        std::invalid_argument("")), "span rejects malformed tile");
      require(throws_as([&] {
        (void)hevc::encode(1, [&](std::size_t, hevc::YuvTile& output) { corrupt(output); }, params);
      }, std::invalid_argument("")), "producer rejects malformed tile before any plane copy");
    }
  }
  require(std::filesystem::exists(directory / ".hevc-encoder-caps.json"),
          "malformed tiles must not invalidate encoder capabilities");
}

void test_multiple_cache_directories(const std::filesystem::path& first) {
  const auto second = first / "second";
  const auto first_file = first / ".hevc-encoder-caps.json";
  const auto second_file = second / ".hevc-encoder-caps.json";
  require(hevc::encoder_caps(first).main10, "first directory ready");
  require(hevc::encoder_caps(second).main10, "second directory ready");
  require(std::filesystem::exists(first_file) && std::filesystem::exists(second_file),
          "both directories contain successful capability results");
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(first_file) && !std::filesystem::exists(second_file),
          "invalidation removes every directory's cache");
  const auto fresh = hevc::encoder_caps(first);
  require(fresh.main8 && fresh.main10 && fresh.detail != "cached",
          "first directory must really probe after invalidation");
}

void test_cache_path_resolution(const std::filesystem::path& directory) {
  const auto root = directory / "path-tests";
  constexpr const char* cache_file = ".hevc-encoder-caps.json";
  const auto real = root / "real";
  const auto alias = root / "alias";
  std::filesystem::create_directories(real / "nested");
  std::filesystem::create_directory_symlink(real / "nested", alias);
  require(hevc::encoder_caps(alias / "..").main10, "symlink parent query succeeds");
  require(std::filesystem::exists(real / cache_file) &&
              !std::filesystem::exists(root / cache_file),
          "symlink parent must cache in the filesystem parent, not the lexical parent");
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(real / cache_file), "real parent cache invalidated");

  // weakly_canonical must preserve a suffix that does not exist yet, including
  // when its existing prefix is a symlink.
  const auto missing = alias / "one" / "two" / "three";
  require(hevc::encoder_caps(missing).main10, "missing suffix query succeeds");
  const auto actual = real / "nested" / "one" / "two" / "three" / cache_file;
  require(std::filesystem::exists(actual), "missing multilevel suffix cache created");
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(actual), "missing suffix cache invalidated");

  const auto plain_missing = root / "future" / "one" / "two";
  require(hevc::encoder_caps(plain_missing).main10, "plain missing suffix query succeeds");
  require(std::filesystem::exists(plain_missing / cache_file),
          "plain missing multilevel suffix cache created");
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(plain_missing / cache_file),
          "plain missing suffix cache invalidated");

  const auto a = root / "a";
  const auto b = root / "b";
  std::filesystem::create_directories(a);
  std::filesystem::create_directories(b);
  std::filesystem::remove(alias);
  std::filesystem::create_directory_symlink(a, alias);
  require(hevc::encoder_caps(alias).main10, "first symlink target query succeeds");
  require(std::filesystem::exists(a / cache_file), "first target cached");
  std::filesystem::remove(alias);
  std::filesystem::create_directory_symlink(b, alias);
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(a / cache_file), "retargeting must not hide old cache");
  std::filesystem::remove(alias);
  std::filesystem::create_directory_symlink(a, alias);
  const auto fresh = hevc::encoder_caps(alias);
  require(fresh.main10 && fresh.detail != "cached", "old target really reprobes after invalidation");
  hevc::invalidate_encoder_caps();

  // A symlink loop gives a deterministic resolution error even when tests run
  // with permission to read all normal directories. The probe must still run.
  const auto loop = root / "loop";
  std::filesystem::create_symlink("loop", loop);
  const auto uncached = hevc::encoder_caps(loop / "child");
  require(uncached.main8 && uncached.main10 && uncached.detail != "cached",
          "unresolvable cache path must not prevent capability probing");
  hevc::invalidate_encoder_caps();
}

void test_failures_keep_cache(const std::filesystem::path& directory) {
  const auto file = directory / ".hevc-encoder-caps.json";
  require(std::filesystem::exists(file), "probe result cached on disk");
  const auto tiles = hevc::tiles_from_rgb(600, 64, card(), 1, 8, false);

  hyperdr::CancelToken token;
  token.request();
  {
    hyperdr::CancelScope scope(&token);
    require(throws_as([&] { (void)hevc::encode(tiles, {}); }, hyperdr::Cancelled()),
            "cancelled encode throws Cancelled");
  }
  hevc::EncodeParams wrong;
  wrong.main10 = true;  // 8-bit tiles
  require(throws_as([&] { (void)hevc::encode(tiles, wrong); }, std::invalid_argument("")),
          "depth mismatch is an argument error");
  hevc::EncodeParams colour;
  colour.color.transfer = 7;
  require(throws_as([&] { (void)hevc::encode(tiles, colour); }, std::invalid_argument("")),
          "unknown transfer is an argument error");
  require(std::filesystem::exists(file), "cancellation and argument errors keep the cache");

  // A damaged cache is a miss: the next query probes and rewrites it.
  hevc::invalidate_encoder_caps();
  require(!std::filesystem::exists(file), "invalidation removes the cache file");
  hyperdr::write_text_file_atomic(file, "{not json", true);
  const auto caps = hevc::encoder_caps(directory);
  require(caps.main8 && caps.main10 && caps.detail != "cached", "damaged cache probes again");
  const auto text = hyperdr::read_binary_file(file);
  require(std::string(text.begin(), text.end()).find("\"main10\":true") != std::string::npos,
          "rewritten cache");

  // A matching entry is used without probing; another macOS build is a miss.
  char build[64] = {};
  std::size_t size = sizeof(build);
  require(sysctlbyname("kern.osversion", build, &size, nullptr, 0) == 0, "read OS build");
  const auto entry = [&](const std::string& system) {
    return "{\"format\":1,\"os_build\":\"" + system + "\",\"main8\":true,\"main10\":true}";
  };
  hevc::invalidate_encoder_caps();
  hyperdr::write_text_file_atomic(file, entry(build), true);
  require(hevc::encoder_caps(directory).detail == "cached", "valid cache is used");
  hevc::invalidate_encoder_caps();
  hyperdr::write_text_file_atomic(file, entry("0A0"), true);
  require(hevc::encoder_caps(directory).detail != "cached", "other OS build probes again");
}

void test_nal_policy() {
  hevc::EncodedSequence sets;sets.vps={64,1,128};sets.sps={66,1,128};sets.pps={68,1,128};
  for(const int length_size:{1,2,4}) {
    const auto framed=[&](unsigned type){std::vector<std::uint8_t> out;
      for(int i=length_size-1;i>=0;--i)out.push_back(3U>>(8*i));
      out.insert(out.end(),{static_cast<std::uint8_t>(type<<1),1,128});return out;};
    const auto idr=framed(20);
    for(unsigned type=0;type<64;++type){
      auto sample=idr;const auto extra=framed(type);sample.insert(sample.end(),extra.begin(),extra.end());
      const bool accepted=type==19||type==20||(type>=32&&type<=35)||type==38||type==39||type==40||type>=48;
      bool rejected=false;std::vector<std::uint8_t> clean;
      try{clean=hevc::testing::repack_sample(sample,length_size,sets);}catch(const std::runtime_error&){rejected=true;}
      require(rejected!=accepted,"NAL policy mismatch type="+std::to_string(type));
      if(accepted){
        const bool retained=type==19||type==20||type==38;
        const std::vector<std::uint8_t> one{0,0,0,3,40,1,128};
        auto expected=one;if(retained){const std::vector<std::uint8_t> other{0,0,0,3,static_cast<std::uint8_t>(type<<1),1,128};expected.insert(expected.end(),other.begin(),other.end());}
        require(clean==expected,"unexpected NAL retained or discarded");
      }
    }
  }
}
void check_audit(const hevc::testing::AuditedSequence& audit,int depth,const std::string& label){
    std::size_t count62=0,bytes62=0,total_unspecified=0;
    for(const auto& sample:audit.with_unspecified.samples)for(std::size_t at=0;at<sample.size();){
      unsigned length=0;for(int i=0;i<4;++i)length=(length<<8)|sample[at++];
      const auto type=(sample[at]>>1)&63;
      if(type>=48)++total_unspecified;
      if(type==62){++count62;bytes62+=length;}
      at+=length;
    }
    const auto before=hevc::decode(audit.with_unspecified,depth),after=hevc::decode(audit.filtered,depth);
    require(before.size()==after.size(),"UNSPEC filtering changed picture count");
    for(std::size_t i=0;i<before.size();++i)
      require(before[i].luma==after[i].luma&&before[i].chroma==after[i].chroma,"UNSPEC filtering changed decoded pixels");
    std::cout<<"UNSPEC audit "<<label<<" depth="<<depth
             <<" type62_count="<<count62<<" type62_bytes="<<bytes62<<" total_unspecified="<<total_unspecified<<" pixels=identical\n";
    // Also exercise the discard comparison even on an OS/encoder which emits
    // no private NALs for this picture. The added UNSPEC62 has no slice data.
    auto injected=audit.filtered;
    for(auto& sample:injected.samples)sample.insert(sample.end(),{0,0,0,4,124,1,128,1});
    const auto artificial=hevc::decode(injected,depth);
    for(std::size_t i=0;i<after.size();++i)
      require(artificial[i].luma==after[i].luma&&artificial[i].chroma==after[i].chroma,"synthetic UNSPEC62 changed pixels");
}
void test_unspecified_pixels() {
  hyperdr::PhotoRenditions photo;
  photo.hdr=hyperdr::FloatImage(3073,65,3);
  for(unsigned y=0;y<65;++y)for(unsigned x=0;x<3073;++x){
    const float level=.05F+3.5F*float(x%257)/256.F;
    photo.hdr.at(x,y,0)=level;photo.hdr.at(x,y,1)=level*(.5F+.4F*float(y%31)/30.F);photo.hdr.at(x,y,2)=level*.3F;
  }
  photo.sdr=photo.hdr;photo.hdr_is_source=true;photo.stats.headroom_stops=3;
  const auto rendered=hyperdr::gain_map_from_renditions(std::move(photo),hyperdr::GainMapWriterProfile::apple_strict);
  for(const int base_depth:{8,10})for(const bool fast:{false,true})for(const bool gain:{false,true}){
    const int depth=gain?8:base_depth;
    const auto& image=gain?rendered.gain_map:rendered.base_linear;
    const auto grid=hevc::tile_grid(image.width,image.height);
    hevc::EncodeParams params{gain?95:82,depth==10,fast,gain?hevc::ColorDescription{2,2,1}:hevc::ColorDescription{12,13,1}};
    auto audit=hevc::testing::encode_audited(grid.count(),[&](std::size_t index,hevc::YuvTile& tile){
      if(gain)hevc::luma_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
        for(unsigned i=0;i<count;++i)row[i]=image.at(x+i,y,0);
      },tile);
      else hevc::rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
        for(unsigned i=0;i<count;++i)for(unsigned c=0;c<3;++c)row[i*3+c]=hyperdr::srgb_oetf(image.at(x+i,y,c));
      },1,true,tile);
    },params);
    check_audit(audit,depth,"base_depth="+std::to_string(base_depth)+" role="+(gain?"gain":"base")+" preset="+(fast?"medium":"slow"));
  }
  for(const int transfer:{16,18})for(const bool fast:{false,true}){
    constexpr unsigned width=2051,height=67;
    const auto grid=hevc::tile_grid(width,height);
    hevc::EncodeParams params{82,true,fast,{9,transfer,9}};
    auto audit=hevc::testing::encode_audited(grid.count(),[&](std::size_t index,hevc::YuvTile& tile){
      hevc::rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
        for(unsigned i=0;i<count;++i){
          const float level=.05F+3.5F*float((x+i)%257)/256.F;
          const auto wide=hyperdr::p3_to_rec2020(level,level*(.5F+.4F*float(y%31)/30.F),level*.3F);
          const std::array<float,3> linear{std::max(0.F,wide[0]),std::max(0.F,wide[1]),std::max(0.F,wide[2])};
          const auto encoded=transfer==16?std::array<float,3>{hyperdr::pq_oetf(linear[0]),hyperdr::pq_oetf(linear[1]),hyperdr::pq_oetf(linear[2])}:hyperdr::hlg_encode(linear);
          std::copy(encoded.begin(),encoded.end(),row+i*3);
        }
      },9,true,tile);
    },params);
    check_audit(audit,10,std::string(transfer==16?"PQ":"HLG")+" preset="+(fast?"medium":"slow"));
  }

}

void* small_stack_round_trip(void* result) {
  auto& ok = *static_cast<std::atomic<int>*>(result);
  try {
    const auto tiles = hevc::tiles_from_rgb(512, 512, card(), 1, 8, true);
    const auto decoded = hevc::decode(hevc::encode(tiles, {}), 8);
    test_unspecified_pixels();
    ok = decoded.size() == 1 ? 1 : -1;
  } catch (const std::exception& error) {
    std::cerr << "small stack: " << error.what() << "\n";
    ok = -1;
  }
  return nullptr;
}

void test_small_stack() {
  pthread_attr_t attributes;
  pthread_attr_init(&attributes);
  pthread_attr_setstacksize(&attributes, 512 * 1024);
  std::atomic<int> ok{0};
  pthread_t thread;
  require(pthread_create(&thread, &attributes, &small_stack_round_trip, &ok) == 0,
          "start 512 KB thread");
  pthread_join(thread, nullptr);
  pthread_attr_destroy(&attributes);
  require(ok == 1, "encode and decode on a 512 KB stack");
}

}  // namespace

int main() {
  try {
    test_conversion();
    test_quality_map();
    test_nal_policy();

    const auto directory = hyperdr::test::temporary_directory() /
                           ("hyperdr-hevc-test-" + std::to_string(::getpid()));
    std::filesystem::remove_all(directory);
    test_cancelled_first_probe(directory);
    const auto caps = hevc::encoder_caps(directory);
    std::cout << "encoder: main8=" << caps.main8 << " main10=" << caps.main10 << " reason="
              << caps.reason_code << " detail=" << caps.detail << "\n";
    const int probe_status = hyperdr::codec::testing::probe_exit_code(caps);
    if (probe_status == 77) {
      std::cout << "SKIPPED: no HEVC encoder on this machine\n";
      return 77;
    }
    require(probe_status == 0, "HEVC probe failed or Main10 unavailable: " + caps.reason_code + " " + caps.detail);
    require(hevc::encoder_caps(directory).main8, "second query is cached");

    test_sequence(8);
    test_small_stack();
    test_sequence(10);
    test_failures_keep_cache(directory);
    test_producer_tile_validation(directory);
    test_multiple_cache_directories(directory);
    test_cache_path_resolution(directory);
    hevc::invalidate_encoder_caps();
    std::filesystem::remove_all(directory);
    std::cout << "hevc_vt_test passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "hevc_vt_test failed: " << error.what() << "\n";
    return 1;
  }
}

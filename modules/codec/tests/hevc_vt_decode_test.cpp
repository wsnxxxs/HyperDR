#include <mach/mach.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <exception>
#include <iostream>
#include <thread>

#include "hevc_decode_fixture.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
using namespace hyperdr;
namespace h = hyperdr::codec::hevc;
namespace {
void require(bool b, const char* message) {
  if (!b) throw std::runtime_error(message);
}
using Clock = std::chrono::steady_clock;
h::DecodedPicture decode(const h::testing::DecodeFixture& fixture) {
  h::DecodedPicture out;
  h::decode_item(
      fixture.config, 1, [&](std::size_t) { return std::span(fixture.sample); },
      [&](std::size_t, h::DecodedPicture&& p) { out = std::move(p); });
  return out;
}
void put(std::vector<std::uint8_t>& p, std::size_t index, unsigned depth, unsigned code) {
  if (depth == 8)
    p.at(index) = code;
  else {
    auto word = static_cast<std::uint16_t>(code << 6);
    std::memcpy(p.data() + index * 2, &word, 2);
  }
}
std::atomic<bool> conversion_worker_seen{false};
std::vector<float> rgb(const h::DecodedPicture& p, h::YuvRgbParams params) {
  const auto caller = std::this_thread::get_id();
  std::vector<float> out(std::size_t(p.width) * p.height * 3);
  h::yuv_to_rgb(p, params, [&](unsigned y, std::span<const float> row) {
    if (std::this_thread::get_id() != caller)
      conversion_worker_seen.store(true, std::memory_order_relaxed);
    std::copy(row.begin(), row.end(), out.begin() + std::size_t(y) * p.width * 3);
  });
  return out;
}
void roundtrips() {
  unsigned cases = 0;
  double worst = 1000;
  for (unsigned chroma : {0U, 1U, 2U, 3U})
    for (unsigned depth : {8U, 10U})
      for (bool full : {false, true}) {
        if (chroma == 2 && depth == 8) continue;
        for (unsigned size : {256U, 512U, 1024U, 257U}) {
          h::testing::FixtureGeometry geometry{size, size == 257 ? 259U : size, depth, chroma, full,
                                               {}};
          const auto f = h::testing::fixture(geometry);
          const auto a = decode(f), b = decode(f);
          require(a.luma == b.luma && a.chroma == b.chroma, "repeated VT decode differs");
          require(a.width == f.config.width && a.height == f.config.height &&
                      a.width <= f.input.width && a.height <= f.input.height,
                  "decoded geometry differs");
          require(a.bit_depth == depth && a.chroma_format == chroma,
                  "decoded depth/chroma differs");
          double sum = 0;
          for (unsigned y = 0; y < a.height; ++y)
            for (unsigned x = 0; x < a.width; ++x) {
              auto delta = double(a.luma_at(x, y)) - f.input.luma_at(x, y);
              sum += delta * delta;
            }
          const double mse = sum / (double(a.width) * a.height), max = (1U << depth) - 1;
          const double psnr = mse ? 10 * std::log10(max * max / mse) : 1000;
          worst = std::min(worst, psnr);
          if (psnr < 40) {
            std::cerr << "roundtrip " << chroma << '/' << depth << '/' << full << '/' << size
                      << " VUIrange " << bool(f.config.vui_color && f.config.vui_color->full_range)
                      << " PSNR " << psnr << " Y " << a.luma_at(0, 0) << " input "
                      << f.input.luma_at(0, 0) << '\n';
            throw std::runtime_error("VT roundtrip Y-PSNR below 40 dB");
          }
          ++cases;
        }
      }
  for (unsigned location : {0U, 1U}) {
    const auto f = h::testing::fixture({256, 256, 8, 1, true, location});
    // VT may elide the default Left location instead of writing explicit 0.
    // Preserve that absence: our reader's agreed interpretation is centered.
    if (location == 1)
      require(f.config.chroma_location_top == 1, "center VUI chroma position missing");
    require(
        h::conversion_params(f.config).chroma_location == f.config.chroma_location_top.value_or(1),
        "chroma position/default ignored");
  }

  std::cout << cases << " profile/range/size roundtrips; worst Y-PSNR " << worst << " dB\n";
}
// Independent reference weights: form a tensor product over the four closest
// chroma sample centers, then apply the H.273 matrix in code-value units.
double sample(const h::DecodedPicture& p, unsigned x, unsigned y, bool cr, unsigned loc) {
  const double xstep = p.chroma_format == 3 ? 1 : 2, ystep = p.chroma_format == 1 ? 2 : 1;
  const double left = xstep == 1 ? 0 : (loc % 2 ? .5 : 0), top = ystep == 1 ? 0
                                                                            : (loc < 2   ? .5
                                                                               : loc < 4 ? 0
                                                                                         : 1);
  const double xx = std::clamp((x - left) / xstep, 0., double(p.chroma_width() - 1)),
               yy = std::clamp((y - top) / ystep, 0., double(p.chroma_height() - 1));
  auto ix = unsigned(std::floor(xx)), iy = unsigned(std::floor(yy));
  double result = 0;
  for (unsigned j = 0; j < 2; ++j)
    for (unsigned i = 0; i < 2; ++i) {
      double w = (i ? xx - ix : 1 - xx + ix) * (j ? yy - iy : 1 - yy + iy);
      auto cx = std::min(ix + i, p.chroma_width() - 1),
           cy = std::min(iy + j, p.chroma_height() - 1);
      result += w * (cr ? p.cr_at(cx, cy) : p.cb_at(cx, cy));
    }
  return result;
}
void conversion() {
  unsigned cases = 0;
  double worst = 0;
  for (unsigned depth : {8U, 10U})
    for (unsigned chroma : {0U, 1U, 2U, 3U})
      for (bool full : {false, true})
        for (int matrix : {0, 1, 2, 5, 6, 9})
          for (unsigned location = 0; location < 6; ++location)
            for (unsigned pattern = 0; pattern < 3; ++pattern) {
              h::DecodedPicture p{17, 67, depth, chroma, {}, {}};
              p.luma.resize(p.luma_row_bytes() * p.height);
              p.chroma.resize(p.chroma_row_bytes() * p.chroma_height());
              const unsigned scale = 1U << (depth - 8), maximum = (1U << depth) - 1;
              for (unsigned y = 0; y < p.height; ++y)
                for (unsigned x = 0; x < p.width; ++x)
                  put(p.luma, std::size_t(y) * p.width + x, depth,
                      (64 + (pattern == 0   ? 0
                             : pattern == 1 ? (x >= 8 ? 100 : 0)
                                            : (x * 7 + y * 2) % 140)) *
                          scale);
              for (unsigned y = 0; y < p.chroma_height(); ++y)
                for (unsigned x = 0; x < p.chroma_width(); ++x) {
                  auto index = (std::size_t(y) * p.chroma_width() + x) * 2;
                  put(p.chroma, index, depth,
                      (pattern == 0   ? 160
                       : pattern == 1 ? (x < 4 ? 80 : 176)
                                      : 64 + (x * 11 + y * 3) % 128) *
                          scale);
                  put(p.chroma, index + 1, depth,
                      (pattern == 0   ? 96
                       : pattern == 1 ? (y < 4 ? 192 : 64)
                                      : 192 - (x * 3 + y * 7) % 128) *
                          scale);
                }
              h::YuvRgbParams params{matrix, full, location, false};
              auto actual = rgb(p, params);
              params.parallel_rows = true;
              const auto parallel = rgb(p, params);
              require(actual.size() == parallel.size() &&
                          std::memcmp(actual.data(), parallel.data(), actual.size()*sizeof(float)) == 0,
                      "serial/parallel float RGB bytes differ");
              const double yspan = full ? maximum : 219 * scale,
                           cspan = full ? maximum : 224 * scale, off = full ? 0 : 16 * scale,
                           mid = 128 * scale;
              const double kr = matrix == 1   ? .2126
                                : matrix == 9 ? .2627
                                              : .299,
                           kb = matrix == 1   ? .0722
                                : matrix == 9 ? .0593
                                              : .114;
              for (unsigned y = 0; y < p.height; ++y)
                for (unsigned x = 0; x < p.width; ++x) {
                  double g = (p.luma_at(x, y) - off) / yspan, r = g, b = g;
                  if (chroma) {
                    double cb = sample(p, x, y, false, location),
                           cr = sample(p, x, y, true, location);
                    if (matrix == 0) {
                      r = (cr - off) / yspan;
                      b = (cb - off) / yspan;
                    } else {
                      r += 2 * (1 - kr) * (cr - mid) / cspan;
                      b += 2 * (1 - kb) * (cb - mid) / cspan;
                      g -= (2 * kr * (1 - kr) * (cr - mid) + 2 * kb * (1 - kb) * (cb - mid)) /
                           ((1 - kr - kb) * cspan);
                    }
                  }
                  const double expected[] = {r, g, b};
                  for (unsigned c = 0; c < 3; ++c) {
                    double error = std::abs(actual[(std::size_t(y) * p.width + x) * 3 + c] -
                                            expected[c]);
                    error *= maximum;
                    worst = std::max(worst, error);
                    require(error <= .001, "unclipped float RGB analytic error above .001 code");
                  }
                }
              ++cases;
            }
  h::DecodedPicture invalid{0xFFFFFFFFU, 0xFFFFFFFFU, 10, 3, {}, {}};
  bool invalid_rejected = false;
  try {
    h::yuv_to_rgb(invalid, {}, [](unsigned, std::span<const float>) {});
  } catch (const std::exception&) {
    invalid_rejected = true;
  }
  require(invalid_rejected, "oversized YUV conversion accepted");
  HvcConfig config;
  auto defaults = h::conversion_params(config);
  require(defaults.matrix == 6 && !defaults.full_range && defaults.chroma_location == 1,
          "missing VUI defaults differ");
  config.vui_color = HeifNclx{1, 13, 9, true};
  config.chroma_location_top = 0;
  HeifNclx authoritative{12, 16, 1, false};
  auto nclx = h::conversion_params(config, &authoritative);
  require(nclx.matrix == 1 && !nclx.full_range && nclx.chroma_location == 0,
          "nclx did not override VUI");
  auto vui = h::conversion_params(config);
  require(vui.matrix == 9 && vui.full_range, "VUI fallback differs");
  require(conversion_worker_seen.load(), "RGB parallel test never reached a worker thread");
  std::cout << cases << " analytic RGB cases; max error " << worst
            << " code; serial/parallel exact\n";
}
void bad_samples() {
  const auto fixture = h::testing::fixture({256, 256, 8, 1, true, {}});
  unsigned failures = 0;
  auto reject = [&](const std::vector<std::uint8_t>& bytes, const char* feature = "") {
    bool rejected = false;
    try {
      h::decode_item(
          fixture.config, 1, [&](std::size_t) { return std::span(bytes); },
          [](std::size_t, h::DecodedPicture&&) {});
    } catch (const HeifReadError& e) {
      require(e.feature() == feature, "malformed sample error feature differs");
      rejected = true;
    }
    require(rejected, "malformed HEVC sample was accepted");
    ++failures;
  };
  auto bad = fixture.sample;
  bad[4] |= 128;
  reject(bad);
  bad = fixture.sample;
  bad[5] |= 8;
  reject(bad);
  bad = fixture.sample;
  bad[5] &= 248;
  reject(bad);
  bad = fixture.sample;
  bad[3] = 255;
  reject(bad);
  bad = fixture.sample;
  bad.pop_back();
  reject(bad);
  reject({0, 0, 0, 2, 78, 1});
  bad = fixture.sample;
  bad.insert(bad.end(), fixture.sample.begin(), fixture.sample.end());
  reject(bad);
  const auto& ps = fixture.config.parameter_sets.front();
  bad = {0, 0, 0, static_cast<std::uint8_t>(ps.size())};
  require(ps.size() < 256, "fixture VPS too big");
  bad.insert(bad.end(), ps.begin(), ps.end());
  bad.back() ^= 1;
  bad.insert(bad.end(), fixture.sample.begin(), fixture.sample.end());
  reject(bad, "hevc_parameter_change");
  // Preserve lengths and legal NAL headers; destroy slice payload so VT, rather
  // than the framing parser, reports its callback error.
  bad = fixture.sample;
  std::size_t at = 0;
  while (at < bad.size()) {
    unsigned n = 0;
    for (unsigned i = 0; i < 4; ++i) n = (n << 8) | bad[at + i];
    auto type = (bad[at + 4] >> 1) & 63;
    if (type <= 31 && n > 3) std::fill(bad.begin() + at + 7, bad.begin() + at + 4 + n, 0);
    at += 4 + n;
  }
  reject(bad);
  // Real access units with a two-byte NAL length field must decode too.
  auto short_config = fixture.config;
  short_config.length_size = 2;
  short_config.record[21] = (short_config.record[21] & 252) | 1;
  std::vector<std::uint8_t> short_sample;
  at = 0;
  while (at < fixture.sample.size()) {
    unsigned n = 0;
    for (unsigned i = 0; i < 4; ++i) n = (n << 8) | fixture.sample[at + i];
    require(n < 65536, "fixture NAL too big for two-byte prefix");
    short_sample.push_back(n >> 8);
    short_sample.push_back(n);
    short_sample.insert(short_sample.end(), fixture.sample.begin() + at + 4,
                        fixture.sample.begin() + at + 4 + n);
    at += 4 + n;
  }
  h::DecodedPicture short_picture;
  h::decode_item(
      short_config, 1, [&](std::size_t) { return std::span(short_sample); },
      [&](std::size_t, h::DecodedPicture&& p) { short_picture = std::move(p); });
  auto ordinary = decode(fixture);
  require(short_picture.luma == ordinary.luma && short_picture.chroma == ordinary.chroma,
          "NAL length-size changed decoded codes");
  auto unsupported = fixture.config;
  unsupported.bit_depth = 12;
  bool rejected12 = false;
  try {
    h::decode_item(
        unsupported, 1, [&](std::size_t) { return std::span(fixture.sample); },
        [](std::size_t, h::DecodedPicture&&) {});
  } catch (const HeifReadError& e) {
    rejected12 = e.feature() == "hevc_12bit" && std::string(e.code()) == "unsupported_format";
  }
  require(rejected12, "12-bit unsupported feature missing");
  std::cout << failures << " corrupt/framing/multi-picture samples rejected\n";
}
void preflight_cancellation() {
  const auto fixture = h::testing::fixture({256, 256, 8, 1, true, {}});
  // Many short legal NAL headers exercise the scan, rather than jumping over
  // one large payload. Cancel before the untrusted access unit reaches VT.
  std::vector<std::uint8_t> sample(32U * 1024 * 1024 / 6 * 6);
  for (std::size_t at = 0; at < sample.size(); at += 6) {
    sample[at + 3] = 2;
    sample[at + 4] = 0x4e;
    sample[at + 5] = 1;
  }
  sample.insert(sample.end(), fixture.sample.begin(), fixture.sample.end());
  CancelToken token;
  CancelScope scope(&token);
  bool caught = false;
  Clock::time_point requested;
  std::thread requester([&] {
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
    requested = Clock::now();
    token.request();
  });
  try {
    validate_hevc_sample(sample, fixture.config);
  } catch (const Cancelled&) {
    caught = true;
  } catch (...) {
    requester.join();
    throw;
  }
  requester.join();
  const auto ms = std::chrono::duration<double, std::milli>(Clock::now() - requested).count();
  require(caught && ms <= 200, "NAL preflight cancellation above 200ms");
  std::cout << "32MiB NAL preflight cancellation " << ms << "ms\n";
}
void cancellation_and_progress() {
  const auto f = h::testing::fixture({3200, 2112, 10, 2, true, {}});
  for (bool first : {true, false}) {
    CancelToken token;
    bool caught = false;
    Clock::time_point requested;
    std::atomic<bool> submitted = false, finished = false;
    std::atomic<unsigned> delivered = 0;
    std::thread requester;
    if (first)
      requester = std::thread([&] {
        while (!submitted && !finished) std::this_thread::yield();
        if (!finished) {
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
          requested = Clock::now();
          token.request();
        }
      });
    h::DecodeParams params;
    params.cancel = &token;
    params.progress = [&](std::size_t done, std::size_t) {
      if (!first && done == 1) {
        requested = Clock::now();
        token.request();
      }
    };
    try {
      h::decode_item(
          f.config, 9,
          [&](std::size_t) {
            submitted = true;
            return std::span(f.sample);
          },
          [&](std::size_t, h::DecodedPicture&&) { ++delivered; }, params);
    } catch (const Cancelled&) {
      caught = true;
    } catch (...) {
      finished = true;
      if (requester.joinable()) requester.join();
      throw;
    }
    finished = true;
    if (requester.joinable()) requester.join();
    const auto ms = std::chrono::duration<double, std::milli>(Clock::now() - requested).count();
    require(caught, "VT cancellation not propagated");
    require(delivered == (first ? 0U : 1U), "cancellation did not occur at intended tile boundary");
    require(ms <= 200, "VT cancellation above 200ms");
    std::cout << (first ? "during first" : "between") << " Sony-size tile cancellation " << ms
              << "ms\n";
  }
  std::size_t previous = 0, calls = 0;
  h::DecodeParams params;
  params.progress = [&](std::size_t done, std::size_t total) {
    require(total == 8 && done >= previous && done <= total, "nonmonotonic progress");
    previous = done;
    ++calls;
  };
  h::decode_item(
      f.config, 8, [&](std::size_t) { return std::span(f.sample); },
      [](std::size_t, h::DecodedPicture&&) {}, params);
  require(previous == 8 && calls == 9, "incomplete progress");
}
std::uint64_t footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  require(task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) ==
              KERN_SUCCESS,
          "task footprint failed");
  return info.phys_footprint;
}
void memory_grid() {
  // 9504x6336 = the Sony 61MP raster, fed by one reused synthetic tile sample.
  // Allocate the final float RGB only; each tile's YUV/RGB scratch is
  // transient.
  const auto f = h::testing::fixture({512, 512, 8, 1, true, {}});
  constexpr unsigned w = 9504, hgt = 6336, cols = (w + 511) / 512, rows = (hgt + 511) / 512;
  const auto before = footprint();
  std::vector<float> output(std::size_t(w) * hgt * 3, 0);
  const auto output_bytes = output.size() * sizeof(float);
  std::atomic<bool> stop = false;
  std::atomic<std::uint64_t> peak = footprint();
  std::thread sampler([&] {
    while (!stop.load()) {
      auto now = footprint(), old = peak.load();
      while (old < now && !peak.compare_exchange_weak(old, now)) {
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
  });
  try {
    h::decode_item(
        f.config, cols * rows, [&](std::size_t) { return std::span(f.sample); },
        [&](std::size_t index, h::DecodedPicture&& p) {
          auto params = h::conversion_params(f.config);
          h::yuv_to_rgb(p, params, [&](unsigned y, std::span<const float> rgb) {
            auto dy = unsigned(index / cols) * 512 + y;
            if (dy >= hgt) return;
            auto x0 = unsigned(index % cols) * 512;
            auto count = std::min(512U, w - x0);
            auto* dst = output.data() + (std::size_t(dy) * w + x0) * 3;
            for (unsigned x = 0; x < count * 3; ++x) dst[x] = rgb[x];
          });
        });
  } catch (...) {
    stop = true;
    sampler.join();
    throw;
  }
  stop = true;
  sampler.join();
  auto extra = peak.load() > before + output_bytes ? peak.load() - before - output_bytes : 0;
  std::cout << "61MP grid " << cols * rows << " tiles output " << output_bytes << "B peak "
            << peak.load() << "B baseline " << before << "B incremental overhead " << extra
            << "B\n";
#if !defined(__has_feature)
#define __has_feature(x) 0
#endif
#if !__has_feature(address_sanitizer)
  require(peak.load() <= output_bytes + 64U * 1024 * 1024, "grid footprint above output + 64MB");
#endif
  require(output.front() > 0 && output.back() > 0, "grid output incomplete");
}
void private_tiles(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  const auto file = read_heif(bytes);
  auto decode_plan = [&](const HeifImagePlan& plan) {
    std::vector<std::uint8_t> sample;
    std::uint64_t sum = 0;
    h::decode_item(
        plan.config, plan.tiles.size(),
        [&](std::size_t i) {
          sample.clear();
          for (const auto& e : plan.tiles[i].extents)
            sample.insert(sample.end(), bytes.begin() + e.offset,
                          bytes.begin() + e.offset + e.length);
          return std::span(sample);
        },
        [&](std::size_t, h::DecodedPicture&& p) {
          for (auto b : p.luma) sum = sum * 1099511628211ULL + b;
        });
    std::cout << "private " << path.filename() << " item " << plan.item_id << ' ' << plan.width
              << 'x' << plan.height << " tiles " << plan.tiles.size() << " tile "
              << plan.config.width << 'x' << plan.config.height << " chroma "
              << plan.config.chroma_format << " depth " << plan.config.bit_depth << " range "
              << bool(plan.config.vui_color && plan.config.vui_color->full_range) << " hash " << sum
              << '\n';
  };
  decode_plan(file.resolve_image());
  if (auto gain = file.resolve_gain_map()) decode_plan(gain->gain);
}
struct Arguments {
  std::string mode;
  std::filesystem::path path;
  std::exception_ptr error;
};
void* run(void* context) {
  auto& args = *static_cast<Arguments*>(context);
  try {
    if (args.mode == "memory")
      memory_grid();
    else if (args.mode == "private")
      private_tiles(args.path);
    else {
      conversion();
      bad_samples();
      roundtrips();
      preflight_cancellation();
      cancellation_and_progress();
    }
  } catch (...) {
    args.error = std::current_exception();
  }
  return nullptr;
}
}  // namespace
int main(int argc, char** argv) {
  try {
    Arguments args{argc > 1 ? argv[1] : "all", argc > 2 ? argv[2] : "", {}};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_t thread;
    require(!pthread_create(&thread, &attr, run, &args), "pthread create failed");
    pthread_join(thread, nullptr);
    pthread_attr_destroy(&attr);
    if (args.error) std::rethrow_exception(args.error);
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}

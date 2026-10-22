#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#include <mach/mach.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <iostream>
#include <thread>

#include "../../../tests/support/temp_directory.hpp"
#include "heif_fixture_edit.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/image/orientation.hpp"
#include "internal/icc_profiles.hpp"
using namespace hyperdr;
namespace {
void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
DecodedImage decode(const std::vector<std::uint8_t>& bytes, RawDecodeOptions options = {}) {
  auto p = test::temporary_directory() / "input-reader.heic";
  write_binary_file_atomic(p, bytes, true);
  return decode_image(p, options);
}
// The orientation ImageIO derives from the container's transforms (and Exif).
unsigned imageio_orientation(const std::vector<std::uint8_t>& bytes) {
  const auto data = CFDataCreate(nullptr, bytes.data(), CFIndex(bytes.size()));
  const auto source = CGImageSourceCreateWithData(data, nullptr);
  require(source != nullptr, "ImageIO cannot open the synthetic HEIC");
  const auto info = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
  require(info != nullptr, "ImageIO has no properties for the synthetic HEIC");
  int value = 0;
  const auto number = static_cast<CFNumberRef>(
      CFDictionaryGetValue(info, kCGImagePropertyOrientation));
  if (number) CFNumberGetValue(number, kCFNumberIntType, &value);
  CFRelease(info);
  CFRelease(source);
  CFRelease(data);
  return unsigned(value ? value : 1);
}
std::uint64_t footprint() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  require(task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) ==
              KERN_SUCCESS,
          "task footprint failed");
  return info.phys_footprint;
}
std::vector<std::uint8_t> properties(std::vector<std::uint8_t> bytes,
                                     std::vector<heif_fixture::Box> extra) {
  const auto primary = read_heif(bytes).primary_item_id;
  return heif_fixture::edit(bytes, [&](auto& meta) {
    for (auto& b : meta)
      if (b.type == "iprp")
        heif_fixture::children(b, 0, [&](auto& iprp) {
          unsigned count = 0;
          for (auto& c : iprp)
            if (c.type == "ipco")
              heif_fixture::children(c, 0, [&](auto& props) {
                count = props.size();
                props.insert(props.end(), extra.begin(), extra.end());
              });
          for (auto& c : iprp)
            if (c.type == "ipma") {
              require(c.data[0] == 0 && !(c.data[3] & 1), "unexpected fixture ipma");
              for (unsigned i = 0, p = 8; i < heif_fixture::get(c.data, 4, 4); ++i) {
                auto id = heif_fixture::get(c.data, p, 2);
                auto n = c.data[p + 2];
                if (id == primary) {
                  for (unsigned k = 0; k < extra.size(); ++k)
                    c.data.insert(c.data.begin() + p + 3 + n + k, 128 + count + k + 1);
                  c.data[p + 2] += extra.size();
                  break;
                }
                p += 3 + n;
              }
            }
        });
  });
}
void run() {
  namespace h = codec::hevc;
  h::EncodeParams params;
  params.quality = 100;
  params.color = {12, 13, 1};
  auto stream = h::encode(
      4,
      [](std::size_t i, h::YuvTile& tile) {
        h::rgb_tile(
            h::tile_grid(1024, 1024), i,
            [&](auto, auto, auto n, float* row) {
              for (unsigned x = 0; x < n; ++x) {
                row[x * 3] = .1F + .15F * i;
                row[x * 3 + 1] = .3F;
                row[x * 3 + 2] = .5F;
              }
            },
            1, false, tile);
      },
      params);
  HeifEncodedImage image{stream, 700, 600, {12, 13, 1, true}, std::nullopt, {}};
  const auto bytes = write_heif(image);
  const auto base = decode(bytes);
  require(base.linear_p3.width == 700 && base.linear_p3.height == 600 &&
              base.decode.sensor_width == 700,
          "grid input geometry changed");
  const auto repeated = decode(bytes);
  require(base.linear_p3.pixels == repeated.linear_p3.pixels, "repeated HEIC input pixels changed");
  struct Sink : ProgressSink {
    std::thread::id caller = std::this_thread::get_id();
    double last = 0;
    CancelToken* cancel = nullptr;
    void on_progress(const ProgressEvent& e) override {
      require(std::this_thread::get_id() == caller && e.fraction >= last && e.fraction <= 1,
              "HEIC progress is not monotonic on caller");
      last = e.fraction;
      if (cancel && last > 0) cancel->request();
    }
  } sink;
  RawDecodeOptions progress_options;
  progress_options.progress_sink = &sink;
  require(
      decode(bytes, progress_options).linear_p3.pixels == base.linear_p3.pixels && sink.last == 1,
      "progress changed HEIC input or did not finish");
  CancelToken token;
  sink.last = 0;
  sink.cancel = &token;
  const auto start = std::chrono::steady_clock::now();
  bool cancelled = false;
  {
    CancelScope scope(&token);
    try {
      (void)decode(bytes, progress_options);
    } catch (const Cancelled&) {
      cancelled = true;
    }
  }
  const auto cancel_ms =
      std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
  require(cancelled && sink.last < 1 && cancel_ms <= 200, "HEIC input cancellation above 200ms");
  std::cout << "input tile cancellation including setup: " << cancel_ms << " ms\n";
  // imir axis 0 exchanges top and bottom, axis 1 left and right (as ImageIO
  // reads them). Check each ordering against ImageIO's own
  // reading of the same bytes, on a non-square image whose four tiles differ.
  struct Case {
    const char* name;
    std::vector<heif_fixture::Box> boxes;
    unsigned fixed_orientation;  // what the axis meaning alone requires; 0 = no claim
  };
  const std::vector<Case> cases{
      {"imir0", {{"imir", {0}}}, 4},
      {"imir1", {{"imir", {1}}}, 2},
      {"imir0+irot1", {{"imir", {0}}, {"irot", {1}}}, 0},
      {"irot1+imir0", {{"irot", {1}}, {"imir", {0}}}, 0},
      {"imir1+irot1", {{"imir", {1}}, {"irot", {1}}}, 0},
      {"irot2+imir1", {{"irot", {2}}, {"imir", {1}}}, 0},
      {"imir0+irot3", {{"imir", {0}}, {"irot", {3}}}, 0}};
  for (const auto& c : cases) {
    const auto transformed = properties(bytes, c.boxes);
    const auto orientation = imageio_orientation(transformed);
    if (c.fixed_orientation)
      require(orientation == c.fixed_orientation, "ImageIO reads an unexpected imir axis meaning");
    const auto expected = apply_exif_orientation(base.linear_p3, orientation);
    const auto got = decode(transformed);
    if (got.linear_p3.width != expected.width || got.linear_p3.height != expected.height ||
        got.linear_p3.pixels != expected.pixels) {
      std::cerr << "transform case " << c.name << " (ImageIO orientation " << orientation << ")\n";
      require(false, "container transforms differ from ImageIO's reading");
    }
  }
  {
    // A crop is not an orientation: Exif still applies after it, while a
    // rotation or mirror property replaces Exif even when it is the identity.
    std::vector<std::uint8_t> clap;
    const auto put32 = [&](std::uint32_t v) {
      for (int i = 3; i >= 0; --i) clap.push_back(std::uint8_t(v >> (8 * i)));
    };
    for (auto v : {640U, 1U, 600U, 1U, 0U, 1U, 0U, 1U}) put32(v);
    HeifWriteOptions with_exif;
    // Big-endian TIFF with IFD0 Orientation = 6.
    with_exif.exif = {'M', 'M', 0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0,
                      0,   1,   0, 6,  0, 0, 0, 0, 0, 0, 0,    0};
    const auto tagged = write_heif(image, nullptr, with_exif);
    const auto cropped = decode(properties(tagged, {{"clap", clap}}));
    require(cropped.linear_p3.width == 600 && cropped.linear_p3.height == 640,
            "a clap alone suppressed the Exif orientation");
    const auto identity_rotation = decode(properties(tagged, {{"irot", {0}}}));
    require(identity_rotation.linear_p3.width == 700 && identity_rotation.linear_p3.height == 600,
            "irot 0 did not replace the Exif orientation");
    const auto exif_only = decode(tagged);
    require(exif_only.linear_p3.width == 600 && exif_only.linear_p3.height == 700,
            "Exif orientation was not applied");
  }
  RawDecodeOptions preview;
  preview.preview_max_edge = 128;
  const auto small = decode(bytes, preview);
  require(small.linear_p3.width == 175 && small.linear_p3.height == 150 &&
              small.decode.target_width == 700 && small.decode.decoded_width == 175 &&
              !small.decode.resolution_reduced,
          "grid preview geometry changed");
  const auto identity = heif_fixture::edit(bytes, [](auto& meta) {
    heif_fixture::properties(meta, [](auto& prop) {
      if (prop.type == "ispe") {
        heif_fixture::put(prop.data, 4, 512, 4);
        heif_fixture::put(prop.data, 8, 512, 4);
      }
    });
    for (auto& b : meta) {
      if (b.type == "iinf")
        heif_fixture::children(b, 8, [](auto& items) {
          for (auto& i : items)
            if (i.type == "infe" && heif_fixture::get(i.data, 4, 2) == 1)
              std::copy_n("iden", 4, i.data.begin() + 8);
        });
      if (b.type == "iref")
        heif_fixture::children(b, 4, [](auto& refs) {
          for (auto& r : refs)
            if (r.type == "dimg" && heif_fixture::get(r.data, 0, 2) == 1) {
              heif_fixture::put(r.data, 2, 1, 2);
              r.data.resize(6);
            }
        });
    }
  });
  const auto iden = decode(identity);
  require(iden.linear_p3.width == 512 && iden.linear_p3.height == 512 &&
              iden.linear_p3.at(50, 50, 0) == base.linear_p3.at(50, 50, 0),
          "identity did not select its coded input");
  const auto icc = codec::display_p3_profile();
  auto mixed = image;
  mixed.display_p3_icc = icc;
  const auto with_color = [&](unsigned transfer, bool light) {
    auto encoded = mixed;
    if (light) encoded.light = HeifContentLight{1200, 500};
    return heif_fixture::edit(write_heif(encoded), [&](auto& meta) {
      heif_fixture::properties(meta, [&](auto& prop) {
        if (prop.type == "colr" &&
            std::string(prop.data.begin(), prop.data.begin() + 4) == "nclx") {
          heif_fixture::put(prop.data, 4, 9, 2);
          heif_fixture::put(prop.data, 6, transfer, 2);
          heif_fixture::put(prop.data, 8, 9, 2);
        }
      });
    });
  };
  require(decode(with_color(13, false)).source_color.source == "icc",
          "SDR ICC did not precede nclx");
  const auto pq = decode(with_color(16, true));
  require(pq.source_color.source == "cicp" && pq.source_color.transfer == "PQ" &&
              pq.content_peak_nits == 1200,
          "PQ nclx did not precede SDR ICC or lost clli");
  {
    // A canvas the raster budget cannot hold whole is decoded tile by tile and
    // reduced as it arrives, not refused. The reduction must not depend on how
    // many workers decode tiles.
    const auto reduce = [&](unsigned workers, std::uint64_t memory) {
      ExecutionScope scope({workers, memory});
      return decode(bytes);
    };
    const auto full = base.linear_p3;
    for (unsigned workers : {1U, 4U}) {
      const auto small = reduce(workers, 15ULL * 700 * 600 - 1);
      require(small.linear_p3.width == 350 && small.linear_p3.height == 300 &&
                  small.decode.target_width == 700 && small.decode.resolution_reduced,
              "a memory budget below the canvas did not reduce the decode");
      // Inside a tile the reduction is the exact 2x2 mean.
      for (unsigned c = 0; c < 3; ++c)
        require(std::abs(small.linear_p3.at(100, 100, c) -
                         (full.at(200, 200, c) + full.at(201, 200, c) + full.at(200, 201, c) +
                          full.at(201, 201, c)) /
                             4) < 1e-4F,
                "reduced HEIC pixels are not the box mean of the full decode");
      require(reduce(workers, 15ULL * 700 * 600 - 1).linear_p3.pixels ==
                  reduce(1, 15ULL * 700 * 600 - 1).linear_p3.pixels,
              "reduced HEIC pixels depend on the worker count");
    }
    // 12000x512 is wider than the raster width limit although it is small.
    h::EncodeParams wide_params = params;
    wide_params.quality = 50;
    const auto wide_grid = h::tile_grid(12000, 512);
    auto wide_stream = h::encode(
        wide_grid.columns * wide_grid.rows,
        [&](std::size_t i, h::YuvTile& tile) {
          h::rgb_tile(
              wide_grid, i,
              [&](auto, auto, auto n, float* row) {
                for (unsigned x = 0; x < n * 3; ++x) row[x] = .4F;
              },
              1, false, tile);
        },
        wide_params);
    const auto wide = decode(write_heif({wide_stream, 12000, 512, {12, 13, 1, true}, std::nullopt, {}}));
    require(wide.linear_p3.width == 6000 && wide.linear_p3.height == 256 &&
                wide.decode.target_width == 12000 && wide.decode.resolution_reduced,
            "a 12000x512 HEIC was not decoded reduced");
  }
  {
    // The 61 MP story canvas we export (10200x18134, 720 tiles) must open, and
    // the reduction must not hold the full-resolution planes. One coded tile is
    // referenced by every cell, which the format allows.
    auto one = h::encode(
        1,
        [](std::size_t, h::YuvTile& tile) {
          std::fill(tile.luma.begin(), tile.luma.end(), 100);
          std::fill(tile.chroma.begin(), tile.chroma.end(), 128);
        },
        params);
    const auto story_grid = h::tile_grid(10200, 18134);
    const auto sample = one.samples[0];
    one.samples.assign(story_grid.columns * story_grid.rows, sample);
    const auto story = write_heif({one, 10200, 18134, {12, 13, 1, true}, std::nullopt, {}});
    require(read_heif(story).resolve_image(0, HeifCanvas::Tiled).tiles.size() == 720,
            "story fixture tile count");
    bool raster_refused = false;
    try {
      (void)read_heif(story).resolve_image();
    } catch (const HeifReadError&) {
      raster_refused = true;
    }
    require(raster_refused, "the raster canvas admitted the story size");
#if !defined(__has_feature)
#define __has_feature(x) 0
#endif
#if !__has_feature(address_sanitizer)  // 720 instrumented tile decodes take minutes
    const auto before = footprint();
    std::atomic<bool> stop = false;
    std::atomic<std::uint64_t> peak = before;
    std::thread sampler([&] {
      while (!stop.load()) {
        const auto now = footprint();
        auto old = peak.load();
        while (old < now && !peak.compare_exchange_weak(old, now)) {
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    });
    DecodedImage opened;
    try {
      opened = decode(story);
    } catch (...) {
      stop = true;
      sampler.join();
      throw;
    }
    stop = true;
    sampler.join();
    const auto output_bytes = opened.linear_p3.pixels.size() * sizeof(float);
    std::cout << "story " << opened.linear_p3.width << "x" << opened.linear_p3.height
              << " output " << output_bytes << "B peak " << peak.load() << "B baseline " << before
              << "B\n";
    require(opened.linear_p3.width == 5100 && opened.linear_p3.height == 9067 &&
                opened.decode.target_width == 10200 && opened.decode.target_height == 18134 &&
                opened.decode.resolution_reduced,
            "the story canvas was not reduced to half size");
    require(peak.load() <= before + output_bytes + 128U * 1024 * 1024,
            "story decode held more than its output plus 128 MiB");
#endif
  }
  const auto unsupported = heif_fixture::edit(bytes, [](auto& meta) {
    heif_fixture::properties(meta, [](auto& prop) {
      if (prop.type == "hvcC") prop.type = "zzzz";
    });
  });
  bool refused = false;
  try {
    (void)decode(unsupported);
  } catch (const UnsupportedFormat& e) {
    refused = e.detail_json() == "{\"container\":\"heif\",\"feature\":\"essential_property\"}";
  }
  require(refused, "input did not preserve structured unsupported-format detail");
}
}  // namespace
int main() try {
  run();
  return 0;
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}

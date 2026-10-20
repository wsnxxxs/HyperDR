#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/inspect.hpp"
#include "../../../tests/support/writer_planes.hpp"

#include "hevc/hevc.hpp"
#include "hevc_probe_policy.hpp"
#include "heif_native_decode.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

class WorkerOverride {
 public:
  explicit WorkerOverride(const char* value)
      : scope_({static_cast<unsigned>(std::strtoul(value, nullptr, 10)), 0}) {}
 private:
  hyperdr::ExecutionScope scope_;
};

hyperdr::FloatImage make_image(std::uint32_t width, std::uint32_t height) {
  hyperdr::FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const float level = 0.05F + 3.5F * static_cast<float>(x % 257) / 256.0F;
      image.at(x, y, 0) = level;
      image.at(x, y, 1) = level * (0.5F + 0.4F * static_cast<float>(y % 31) / 30.0F);
      image.at(x, y, 2) = level * 0.3F;
    }
  }
  return image;
}

struct ImageSnapshot {
  int width{};
  int height{};
  int depth{};
  std::array<int, 4> nclx{};
  std::array<int, 2> light{-1, -1};
  std::vector<std::uint8_t> icc;
  std::vector<std::uint8_t> exif;
  std::string xmp;
  std::vector<std::uint8_t> pixels;
  std::vector<std::vector<std::uint8_t>> coded_tiles;
  bool operator==(const ImageSnapshot&) const = default;
};

// One image of the file as our reader describes it, plus the pictures
// VideoToolbox decodes from it (native YUV codes, tile by tile).
ImageSnapshot snapshot_image(const hyperdr::HeifFile& file,
                             const hyperdr::HeifImagePlan& plan, bool primary,
                             std::uint32_t width, std::uint32_t height) {
  ImageSnapshot result;
  result.width = static_cast<int>(plan.width);
  result.height = static_cast<int>(plan.height);
  result.depth = static_cast<int>(plan.config.bit_depth);
  require(plan.width == width && plan.height == height,
          "HEIC grid lost its odd logical image edge");
  require(plan.color.has_value(), "HEIC image lost its nclx profile");
  result.nclx = {plan.color->primaries, plan.color->transfer, plan.color->matrix,
                 plan.color->full_range ? 1 : 0};
  result.icc.assign(plan.icc.begin(), plan.icc.end());
  if (primary) {
    result.exif = file.exif();
    result.xmp = file.xmp();
  }
  if (plan.light) result.light = {plan.light->maximum, plan.light->average};

  require(plan.columns == (width + 511) / 512 && plan.rows == (height + 511) / 512 &&
              plan.tiles.size() == std::size_t(plan.columns) * plan.rows,
          "HEIC grid tile geometry changed");
  for (const auto& tile : plan.tiles) {
    require(file.item(tile.id).type == "hvc1", "HEIC grid tile is not HEVC");
    auto bytes = file.item_bytes(tile.id);
    require(!bytes.empty(), "coded HEIC tile is empty");
    result.coded_tiles.push_back(std::move(bytes));
  }
  heif_native::for_each_picture(file, plan, [&](auto, auto, const heif_native::Picture& picture) {
    result.pixels.insert(result.pixels.end(), picture.luma.begin(), picture.luma.end());
    result.pixels.insert(result.pixels.end(), picture.chroma.begin(), picture.chroma.end());
  });
  require(!result.pixels.empty(), "HEIC image decoded no pictures");
  return result;
}

struct FileSnapshot {
  ImageSnapshot primary;
  std::optional<ImageSnapshot> gain;
  std::vector<std::uint8_t> tmap;
};

FileSnapshot snapshot_file(const std::vector<std::uint8_t>& bytes,
                           std::uint32_t width, std::uint32_t height,
                           bool adaptive, int depth) {
  const auto inspection = hyperdr::inspect_heif(bytes);
  require(inspection.structurally_valid && inspection.has_heic_brand &&
              inspection.has_exif && inspection.has_xmp,
          "HEIC output lost container structure or metadata");
  require(inspection.has_tmap_item == adaptive &&
              inspection.has_tmap_brand == adaptive,
          "HEIC output has the wrong gain-map topology");
  if (adaptive) {
    require(inspection.has_dimg_reference && inspection.has_altr_group &&
                inspection.has_tmap_metadata,
            "Adaptive HEIC lost its gain-map references");
  }
  const auto file = hyperdr::read_heif(bytes);
  const auto primary = file.resolve_image();
  FileSnapshot result{snapshot_image(file, primary, true, width, height)};
  require(!result.primary.exif.empty() && !result.primary.xmp.empty(),
          "HEIC primary lost Exif or XMP");
  require(result.primary.depth == depth, "HEIC primary has the wrong bit depth");
  if (adaptive) {
    require(!result.primary.icc.empty(), "Adaptive HEIC lost its Display P3 ICC");
  } else {
    require(result.primary.light[0] >= 0 && result.primary.light[1] >= 0,
            "BT.2100 HEIC lost its content light level");
  }
  if (adaptive) {
    const auto references = hyperdr::find_tmap_references(bytes);
    require(references.base_id == primary.item_id,
            "TMAP does not reference the primary grid");
    const auto gain_plan = file.resolve_image(references.gain_id);
    result.gain = snapshot_image(file, gain_plan, false, width, height);
    require(result.gain->depth == 8, "HEIC gain map has the wrong bit depth");
    result.tmap = hyperdr::extract_tmap_payload(bytes);
    require(!result.tmap.empty(), "HEIC lost its ISO gain-map payload");
  }
  return result;
}

void compare_images(const ImageSnapshot& serial, const ImageSnapshot& parallel,
                    const std::string& label) {
  require(serial.width == parallel.width && serial.height == parallel.height &&
              serial.depth == parallel.depth, label + " geometry or depth changed");
  require(serial.nclx == parallel.nclx,
          label + " nclx changed");
  // Little CMS creates a fresh ICC on each call. Its creation timestamp lives
  // at header bytes 24..35; every other byte, including the tags, must match.
  require(serial.icc.size() == parallel.icc.size(),
          label + " ICC size changed");
  for (std::size_t i = 0; i < serial.icc.size(); ++i) {
    if (i >= 24 && i < 36) continue;
    require(serial.icc[i] == parallel.icc[i],
            label + " ICC changed outside its creation timestamp");
  }
  require(serial.exif == parallel.exif && serial.xmp == parallel.xmp &&
              serial.light == parallel.light,
          label + " metadata changed");
  require(serial.pixels == parallel.pixels,
          label + " decoded pixels changed");
  require(serial.coded_tiles == parallel.coded_tiles,
          label + " row-major coded HEVC tile bytes changed");
}

void compare_files(const std::vector<std::uint8_t>& serial,
                   const std::vector<std::uint8_t>& parallel,
                   std::uint32_t width, std::uint32_t height,
                   bool adaptive, int depth, const std::string& label) {
  require(serial == parallel, label + " serial/parallel HEIF bytes changed (run with the test clock)");
  const auto before = snapshot_file(serial, width, height, adaptive, depth);
  const auto after = snapshot_file(parallel, width, height, adaptive, depth);
  compare_images(before.primary, after.primary, label + " primary");
  require(before.gain.has_value() == after.gain.has_value(),
          label + " gain-map presence changed");
  if (adaptive) {
    compare_images(*before.gain, *after.gain, label + " gain map");
    require(before.tmap == after.tmap, label + " TMAP payload changed");
  }
}

}  // namespace

int main(int argc, char** argv) {
  try {
    using hyperdr::codec::testing::probe_exit_code;
    if (argc == 2 && std::string_view(argv[1]) == "--probe-policy-test") {
      using hyperdr::codec::hevc::EncoderCaps;
      struct Case { EncoderCaps caps; int expected; };
      for (const auto& test : {
          Case{{false, false, "hevc_unavailable", {}}, 77},
          Case{{false, false, "hevc_probe_failed", {}}, 1},
          Case{{true, false, "hevc_main10_unavailable", {}}, 1},
          Case{{false, false, {}, {}}, 1},
          Case{{true, false, {}, {}}, 1},
          Case{{true, true, "hevc_probe_failed", {}}, 1},
          Case{{true, true, {}, {}}, 0}}) {
        require(probe_exit_code(test.caps) == test.expected,
                "probe failure or missing Main10 must fail, not skip");
      }
      std::cout << "HEVC probe policy: seven deterministic cases passed\n";
      return 0;
    }
    const auto caps = hyperdr::codec::hevc::encoder_caps();
    const int probe_status = probe_exit_code(caps);
    if (probe_status != 0) {
      std::cerr << "HEVC probe: " << caps.reason_code << " " << caps.detail << '\n';
      return probe_status;
    }
    hyperdr::PhotoMetadata metadata;
    metadata.model = "HEIC parallel regression";
    metadata.date_time = "2026:09:23 12:00:00";

    hyperdr::PhotoRenditions adaptive_photo;
    adaptive_photo.hdr = make_image(3073, 65);
    adaptive_photo.sdr = adaptive_photo.hdr;
    adaptive_photo.hdr_is_source = true;
    adaptive_photo.stats.headroom_stops = 3.0F;
    const auto gain = hyperdr::test::encoded_pair(
        std::move(adaptive_photo), true);
    require(gain.gain_map.width == 3073 && gain.gain_map.height == 65,
            "fixture must tile the full-resolution gain map");
    for (const int depth : {8, 10}) {
      std::vector<std::uint8_t> serial;
      std::vector<std::uint8_t> parallel;
      {
        WorkerOverride workers("4");
        parallel = hyperdr::encode_adaptive_heic(gain, metadata, 82, depth);
      }
      {
        WorkerOverride workers("1");
        serial = hyperdr::encode_adaptive_heic(gain, metadata, 82, depth);
      }
      compare_files(serial, parallel, 3073, 65, true, depth,
                    "Adaptive HEIC " + std::to_string(depth) + "-bit");
    }

    hyperdr::PhotoRenditions photo;
    photo.hdr = make_image(2051, 67);
    photo.sdr = photo.hdr;
    photo.stats.headroom_stops = 3.0F;
    for (const auto encoding : {hyperdr::HdrEncoding::Pq,
                                hyperdr::HdrEncoding::Hlg}) {
      std::vector<std::uint8_t> serial;
      std::vector<std::uint8_t> parallel;
      {
        WorkerOverride workers("4");
        parallel = hyperdr::encode_hdr_heic(
            photo, metadata, 82, encoding);
      }
      {
        WorkerOverride workers("1");
        serial = hyperdr::encode_hdr_heic(
            photo, metadata, 82, encoding);
      }
      compare_files(serial, parallel, 2051, 67, false, 10,
                    encoding == hyperdr::HdrEncoding::Pq ? "PQ HEIC" : "HLG HEIC");
    }
    std::cout << "HEIC serial/parallel tile equivalence passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "HEIC parallel test failure: " << error.what() << '\n';
    return 1;
  }
}

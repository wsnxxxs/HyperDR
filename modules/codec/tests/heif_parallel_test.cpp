#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/gainmap/rendition.hpp"

#include <libheif/heif.h>
#include <libheif/heif_items.h>
#include <libheif/heif_tiling.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

void check_heif(heif_error error, const char* action) {
  if (error.code != heif_error_Ok) {
    throw std::runtime_error(std::string(action) + ": " +
                             (error.message ? error.message : "unknown libheif error"));
  }
}

struct ContextDeleter {
  void operator()(heif_context* p) const { heif_context_free(p); }
};
struct HandleDeleter {
  void operator()(heif_image_handle* p) const { heif_image_handle_release(p); }
};
struct ImageDeleter {
  void operator()(heif_image* p) const { heif_image_release(p); }
};

void set_workers(const char* value) {
#ifdef _WIN32
  require(_putenv_s("HYPERDR_HEIC_TILE_WORKERS", value) == 0,
          "cannot set HEIC tile worker override");
#else
  require((value[0] ? setenv("HYPERDR_HEIC_TILE_WORKERS", value, 1)
                    : unsetenv("HYPERDR_HEIC_TILE_WORKERS")) == 0,
          "cannot set HEIC tile worker override");
#endif
}

class WorkerOverride {
 public:
  explicit WorkerOverride(const char* value) {
    if (const char* previous = std::getenv("HYPERDR_HEIC_TILE_WORKERS")) {
      previous_ = previous;
    }
    set_workers(value);
  }
  ~WorkerOverride() {
    try {
      set_workers(previous_ ? previous_->c_str() : "");
    } catch (...) {
    }
  }
  WorkerOverride(const WorkerOverride&) = delete;
  WorkerOverride& operator=(const WorkerOverride&) = delete;

 private:
  std::optional<std::string> previous_;
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
  std::vector<std::vector<std::uint8_t>> exif;
  std::vector<std::vector<std::uint8_t>> xmp;
  std::vector<std::uint8_t> pixels;
  std::vector<std::vector<std::uint8_t>> coded_tiles;
  bool operator==(const ImageSnapshot&) const = default;
};

std::vector<std::vector<std::uint8_t>> metadata_blocks(
    const heif_image_handle* handle, const char* type) {
  const int count = heif_image_handle_get_number_of_metadata_blocks(handle, type);
  require(count >= 0, "cannot count HEIC metadata blocks");
  std::vector<heif_item_id> ids(static_cast<std::size_t>(count));
  require(heif_image_handle_get_list_of_metadata_block_IDs(
              handle, type, ids.data(), count) == count,
          "cannot list HEIC metadata blocks");
  std::vector<std::vector<std::uint8_t>> blocks;
  for (const auto id : ids) {
    std::vector<std::uint8_t> bytes(heif_image_handle_get_metadata_size(handle, id));
    check_heif(heif_image_handle_get_metadata(handle, id, bytes.data()),
               "read HEIC metadata");
    blocks.push_back(std::move(bytes));
  }
  std::sort(blocks.begin(), blocks.end());
  return blocks;
}

void append_plane(std::vector<std::uint8_t>& pixels, const heif_image* image,
                  heif_channel channel, int bytes_per_pixel) {
  const int width = heif_image_get_width(image, channel);
  const int height = heif_image_get_height(image, channel);
  int stride = 0;
  const auto* plane = heif_image_get_plane_readonly(image, channel, &stride);
  require(width > 0 && height > 0 && plane && stride >= width * bytes_per_pixel,
          "decoded HEIC plane is invalid");
  const auto row_bytes = static_cast<std::size_t>(width) * bytes_per_pixel;
  for (int y = 0; y < height; ++y) {
    const auto* row = plane + static_cast<std::size_t>(y) * stride;
    pixels.insert(pixels.end(), row, row + row_bytes);
  }
}

ImageSnapshot snapshot_image(heif_context* context, heif_image_handle* handle,
                             bool gain, std::uint32_t width, std::uint32_t height) {
  ImageSnapshot result;
  result.width = heif_image_handle_get_width(handle);
  result.height = heif_image_handle_get_height(handle);
  result.depth = heif_image_handle_get_luma_bits_per_pixel(handle);
  require(result.width == static_cast<int>(width) &&
              result.height == static_cast<int>(height),
          "HEIC grid lost its odd logical image edge");

  heif_color_profile_nclx* raw_nclx = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(handle, &raw_nclx),
             "read HEIC nclx");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      nclx(raw_nclx, &heif_nclx_color_profile_free);
  require(nclx != nullptr, "HEIC image lost its nclx profile");
  result.nclx = {nclx->color_primaries, nclx->transfer_characteristics,
                 nclx->matrix_coefficients, nclx->full_range_flag};

  result.icc.resize(heif_image_handle_get_raw_color_profile_size(handle));
  if (!result.icc.empty()) {
    check_heif(heif_image_handle_get_raw_color_profile(handle, result.icc.data()),
               "read HEIC ICC profile");
  }
  result.exif = metadata_blocks(handle, "Exif");
  result.xmp = metadata_blocks(handle, "mime");
  heif_content_light_level light{};
  if (heif_image_handle_get_content_light_level(handle, &light)) {
    result.light = {light.max_content_light_level,
                    light.max_pic_average_light_level};
  }

  heif_image* raw_image = nullptr;
  check_heif(heif_decode_image(handle, &raw_image,
                               gain ? heif_colorspace_YCbCr : heif_colorspace_RGB,
                               gain ? heif_chroma_420
                                    : result.depth > 8
                                          ? heif_chroma_interleaved_RRGGBB_LE
                                          : heif_chroma_interleaved_RGB,
                               nullptr),
             "decode HEIC grid");
  std::unique_ptr<heif_image, ImageDeleter> image(raw_image);
  if (gain) {
    for (const auto channel : {heif_channel_Y, heif_channel_Cb, heif_channel_Cr}) {
      append_plane(result.pixels, image.get(), channel, 1);
    }
  } else {
    append_plane(result.pixels, image.get(), heif_channel_interleaved,
                 result.depth > 8 ? 6 : 3);
  }

  heif_image_tiling tiling{};
  check_heif(heif_image_handle_get_image_tiling(handle, 0, &tiling),
             "read HEIC grid tiling");
  require(tiling.num_columns == (width + 2047) / 2048 &&
              tiling.num_rows == (height + 2047) / 2048,
          "HEIC grid tile geometry changed");
  for (std::uint32_t y = 0; y < tiling.num_rows; ++y) {
    for (std::uint32_t x = 0; x < tiling.num_columns; ++x) {
      heif_item_id tile_id = 0;
      check_heif(heif_image_handle_get_grid_image_tile_id(handle, 0, x, y, &tile_id),
                 "find HEIC grid tile");
      require(heif_item_get_item_type(context, tile_id) ==
                  heif_fourcc('h', 'v', 'c', '1'),
              "HEIC grid tile is not HEVC");
      std::uint8_t* raw_data = nullptr;
      std::size_t data_size = 0;
      check_heif(heif_item_get_item_data(context, tile_id, nullptr, &raw_data,
                                         &data_size),
                 "read coded HEIC tile");
      require(raw_data && data_size > 0, "coded HEIC tile is empty");
      result.coded_tiles.emplace_back(raw_data, raw_data + data_size);
      heif_release_item_data(context, &raw_data);
    }
  }
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
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  require(context != nullptr, "cannot allocate HEIC inspection context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "open encoded HEIC");
  heif_image_handle* raw_primary = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &raw_primary),
             "get HEIC primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(raw_primary);
  FileSnapshot result{snapshot_image(context.get(), primary.get(), false,
                                     width, height)};
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
    require(references.base_id == heif_image_handle_get_item_id(primary.get()),
            "TMAP does not reference the primary grid");
    heif_image_handle* raw_gain = nullptr;
    check_heif(heif_context_get_image_handle(context.get(), references.gain_id,
                                             &raw_gain),
               "get HEIC gain-map image");
    std::unique_ptr<heif_image_handle, HandleDeleter> gain(raw_gain);
    result.gain = snapshot_image(context.get(), gain.get(), true, width, height);
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

int main() {
  try {
    hyperdr::PhotoMetadata metadata;
    metadata.model = "HEIC parallel regression";
    metadata.date_time = "2026:09:23 12:00:00";

    hyperdr::PhotoRenditions adaptive_photo;
    adaptive_photo.hdr = make_image(3073, 65);
    adaptive_photo.sdr = adaptive_photo.hdr;
    adaptive_photo.hdr_is_source = true;
    adaptive_photo.stats.headroom_stops = 3.0F;
    const auto gain = hyperdr::gain_map_from_renditions(
        std::move(adaptive_photo), hyperdr::GainMapWriterProfile::apple_strict);
    require(gain.gain_map.width == 3073 && gain.gain_map.height == 65,
            "fixture must tile the full-resolution gain map");
    for (const int depth : {8, 10}) {
      const auto preset = depth == 8 ? hyperdr::HevcPreset::Slow
                                     : hyperdr::HevcPreset::Medium;
      std::vector<std::uint8_t> serial;
      std::vector<std::uint8_t> parallel;
      {
        WorkerOverride workers("4");
        parallel = hyperdr::encode_adaptive_heic(gain, metadata, 82, depth, preset);
      }
      {
        WorkerOverride workers("1");
        serial = hyperdr::encode_adaptive_heic(gain, metadata, 82, depth, preset);
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
            photo, metadata, 82, encoding, hyperdr::HevcPreset::Medium);
      }
      {
        WorkerOverride workers("1");
        serial = hyperdr::encode_hdr_heic(
            photo, metadata, 82, encoding, hyperdr::HevcPreset::Medium);
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

#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/icc_profiles.hpp"

#include <jpeglib.h>
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/frame.hpp"
#include <lcms2.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <csetjmp>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {
void (*jpeg_progress_observer)(bool) = nullptr;
void check_jpeg_dimensions(std::uint32_t width, std::uint32_t height) {
  if (width > 65500 || height > 65500)
    throw ExportDimensionLimit(width, height);
}

struct JpegError {
  jpeg_error_mgr base{};
  std::jmp_buf jump{};
  char message[JMSG_LENGTH_MAX]{};
};

void jpeg_fail(j_common_ptr info) {
  auto* error = reinterpret_cast<JpegError*>(info->err);
  (*info->err->format_message)(info, error->message);
  std::longjmp(error->jump, 1);
}

// Compressed bytes go straight into a vector the caller owns. libjpeg-turbo's
// jpeg_mem_dest reallocates privately and publishes the buffer only when the
// image finishes, so a cancelled or failed compression cannot free it safely.
struct VectorDestination {
  jpeg_destination_mgr pub{};
  std::vector<std::uint8_t> bytes;
};
void vector_init(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  dest->bytes.resize(64 * 1024);
  dest->pub.next_output_byte = dest->bytes.data();
  dest->pub.free_in_buffer = dest->bytes.size();
}
boolean vector_grow(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  const auto used = dest->bytes.size();
  dest->bytes.resize(used * 2);
  dest->pub.next_output_byte = dest->bytes.data() + used;
  dest->pub.free_in_buffer = dest->bytes.size() - used;
  return TRUE;
}
void vector_term(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  dest->bytes.resize(dest->bytes.size() - dest->pub.free_in_buffer);
}

std::vector<std::uint8_t> compress_jpeg(const std::uint8_t* pixels, std::uint32_t width,
                                        std::uint32_t height, int components,
                                        J_COLOR_SPACE color_space, int quality,
                                        const std::vector<std::uint8_t>* exif_tiff = nullptr,
                                        const std::vector<std::uint8_t>* icc = nullptr,
                                        bool full_chroma = false) {
  if (!pixels || width == 0 || height == 0) {
    throw std::invalid_argument("cannot encode an empty JPEG image");
  }

  std::vector<std::uint8_t> icc_marker, exif_marker;
  if (icc && !icc->empty()) {
    icc_marker = {'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    icc_marker.insert(icc_marker.end(), icc->begin(), icc->end());
    if (icc_marker.size() > 65533) throw std::runtime_error("ICC data is too large for JPEG APP2");
  }
  if (exif_tiff && !exif_tiff->empty()) {
    exif_marker = {'E','x','i','f',0,0};
    exif_marker.insert(exif_marker.end(), exif_tiff->begin(), exif_tiff->end());
    if (exif_marker.size() > 65533) throw std::runtime_error("Exif data is too large for JPEG APP1");
  }
  struct State {
    jpeg_compress_struct info{};
    JpegError error{};
    VectorDestination destination;
  };
  auto state = std::make_unique<State>();
  auto& info = state->info;
  auto& error = state->error;
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_compress(&info);
    throw std::runtime_error(std::string("JPEG encode: ") + error.message);
  }

  jpeg_create_compress(&info);
  state->destination.pub.init_destination = vector_init;
  state->destination.pub.empty_output_buffer = vector_grow;
  state->destination.pub.term_destination = vector_term;
  info.dest = &state->destination.pub;
  info.image_width = width;
  info.image_height = height;
  info.input_components = components;
  info.in_color_space = color_space;
  jpeg_set_defaults(&info);
  if (!exif_tiff && !icc) info.write_JFIF_header = FALSE;
  jpeg_set_quality(&info, std::clamp(quality, 0, 100), TRUE);
  if (full_chroma) {
    for (int component = 0; component < info.num_components; ++component) {
      info.comp_info[component].h_samp_factor = 1;
      info.comp_info[component].v_samp_factor = 1;
    }
  }
  info.optimize_coding = TRUE;
  struct Progress {
    jpeg_progress_mgr pub{};
    bool finishing = false;
  } progress;
  progress.pub.progress_monitor = [](j_common_ptr common) {
    const auto* self = reinterpret_cast<const Progress*>(common->progress);
    if (jpeg_progress_observer) jpeg_progress_observer(self->finishing);
    check_cancelled();
  };
  info.progress = &progress.pub;
  try {
  jpeg_start_compress(&info, TRUE);

  if (!icc_marker.empty()) jpeg_write_marker(&info, JPEG_APP0 + 2, icc_marker.data(), icc_marker.size());
  if (!exif_marker.empty()) jpeg_write_marker(&info, JPEG_APP0 + 1, exif_marker.data(), exif_marker.size());

  const std::size_t stride = static_cast<std::size_t>(width) * components;
  while (info.next_scanline < info.image_height) {
    check_cancelled();
    auto* row = const_cast<JSAMPLE*>(
        pixels + static_cast<std::size_t>(info.next_scanline) * stride);
    jpeg_write_scanlines(&info, &row, 1);
  }
  // With optimize_coding the entropy coding and most of the output happen
  // here, so a cancellation lands mid-output as often as not.
  progress.finishing = true;
  jpeg_finish_compress(&info);
  jpeg_destroy_compress(&info);
  return std::move(state->destination.bytes);
  } catch (...) {
    jpeg_destroy_compress(&info); throw;
  }
}

std::vector<std::uint8_t> make_base_jpeg(const FloatImage& image,
                                         const PhotoMetadata& metadata, int quality,
                                         bool clamp_srgb, bool full_chroma) {
  image.require_consistent("gain-map JPEG base");
  check_jpeg_dimensions(image.width, image.height);
  if (image.channels != 3) throw std::invalid_argument("gain-map JPEG base must be RGB");
  std::vector<std::uint8_t> rgb(static_cast<std::size_t>(image.width) * image.height * 3);
  for (std::uint32_t y = 0; y < image.height; ++y) {
    check_cancelled();
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto base = (static_cast<std::size_t>(y) * image.width + x) * 3;
      const auto fitted = clamp_srgb
                              ? compress_linear_p3_to_srgb(
                                    image.pixels[base], image.pixels[base + 1],
                                    image.pixels[base + 2])
                              : std::array<float, 3>{image.pixels[base],
                                                     image.pixels[base + 1],
                                                     image.pixels[base + 2]};
      for (unsigned c = 0; c < 3; ++c) {
        rgb[base + c] = static_cast<std::uint8_t>(quantize_dithered(
            srgb_oetf(fitted[c]), 255, x, y, c));
      }
    }
  }
  const auto exif = make_minimal_exif(metadata);
  // Gamut compression retains P3 coordinates even when clamp_srgb is enabled.
  // Both modes therefore store Display P3 primaries with the sRGB transfer.
  const auto icc = codec::display_p3_profile();
  return compress_jpeg(rgb.data(), image.width, image.height, 3, JCS_RGB, quality, &exif,
                       &icc, full_chroma);
}

std::vector<std::uint8_t> make_gain_jpeg(const FloatImage& image, int quality) {
  if (image.channels != 1 && image.channels != 3) {
    throw std::invalid_argument("gain-map JPEG recovery map must have one or three channels");
  }
  check_jpeg_dimensions(image.width, image.height);
  std::vector<std::uint8_t> pixels(image.pixels.size());
  const std::size_t stride = static_cast<std::size_t>(image.width) * image.channels;
  for (std::uint32_t y = 0; y < image.height; ++y) {
    check_cancelled();
    for (std::size_t i = y * stride; i < (y + 1) * stride; ++i) {
    pixels[i] = static_cast<std::uint8_t>(
        std::lround(std::clamp(image.pixels[i], 0.0F, 1.0F) * 255.0F));
  }
  }
  return compress_jpeg(pixels.data(), image.width, image.height, image.channels,
      image.channels == 1 ? JCS_GRAYSCALE : JCS_RGB, quality, nullptr, nullptr, true);
}

}  // namespace

std::vector<std::uint8_t> encode_sdr_jpeg(const FloatImage& image,
    const PhotoMetadata& metadata, int quality, ColorGamut gamut) {
  image.require_consistent("SDR JPEG");
  check_jpeg_dimensions(image.width, image.height);
  if (image.channels != 3) throw std::invalid_argument("SDR JPEG requires RGB");
  if (gamut != ColorGamut::kSrgb && gamut != ColorGamut::kDisplayP3)
    throw std::invalid_argument("SDR JPEG supports sRGB or Display P3");
  std::vector<std::uint8_t> rgb(image.pixels.size());
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    for (std::uint32_t x=0;x<image.width;++x) {
      const auto i=(static_cast<std::size_t>(y)*image.width+x)*3;
      auto color=fit_linear_p3_gamut(image.pixels[i],image.pixels[i+1],image.pixels[i+2],1.0F,
                                    gamut == ColorGamut::kSrgb);
      if (gamut == ColorGamut::kSrgb) color=linear_p3_to_rec709(color[0],color[1],color[2]);
      for (unsigned c=0;c<3;++c) rgb[i+c]=static_cast<std::uint8_t>(quantize_dithered(srgb_oetf(color[c]),255,x,y,c));
    }
  });
  const auto icc = gamut == ColorGamut::kSrgb ? codec::srgb_profile() : codec::display_p3_profile();
  const auto exif=make_minimal_exif(metadata);
  return compress_jpeg(rgb.data(),image.width,image.height,3,JCS_RGB,quality,&exif,&icc);
}

namespace {
std::array<unsigned, 3> decode_jpeg_for_verification(const std::uint8_t* bytes, std::size_t size, FloatImage* linear = nullptr) {
  struct State { jpeg_decompress_struct info{}; JpegError error{}; };
  auto state = std::make_unique<State>();
  auto& info = state->info;
  auto& error = state->error;
  info.err = jpeg_std_error(&error.base); error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_decompress(&info);
    throw std::runtime_error(std::string("JPEG verification: ") + error.message);
  }
  jpeg_create_decompress(&info);
  try {
    jpeg_mem_src(&info, bytes, static_cast<unsigned long>(size));
    jpeg_read_header(&info, TRUE);
    const std::array<unsigned, 3> result{info.image_width, info.image_height, static_cast<unsigned>(info.num_components)};
    if (linear) {
      info.out_color_space = JCS_RGB;
      *linear = FloatImage(info.image_width, info.image_height, 3);
    }
    jpeg_start_decompress(&info);
    auto row = (*info.mem->alloc_sarray)(reinterpret_cast<j_common_ptr>(&info), JPOOL_IMAGE,
        info.output_width * info.output_components, 1);
    while (info.output_scanline < info.output_height) {
      check_cancelled();
      const auto y = info.output_scanline;
      jpeg_read_scanlines(&info, row, 1);
      if (linear) for (std::uint32_t x = 0; x < info.output_width; ++x)
        for (unsigned c = 0; c < 3; ++c)
          linear->at(x,y,c) = srgb_eotf(row[0][x*3+c] / 255.0F);
    }
    jpeg_finish_decompress(&info);
    const bool warnings = info.err->num_warnings != 0;
    jpeg_destroy_decompress(&info);
    if (warnings) throw std::runtime_error("JPEG verification: corrupt/truncated image data");
    return result;
  } catch (...) { jpeg_destroy_decompress(&info); throw; }
}
}  // namespace
namespace testing {
void set_jpeg_progress_observer(void (*observer)(bool finishing)) {
  jpeg_progress_observer = observer;
}
}  // namespace testing

void verify_sdr_jpeg(const std::vector<std::uint8_t>& bytes) {
  (void)decode_jpeg_for_verification(bytes.data(), bytes.size());
}

std::vector<std::uint8_t> encode_gain_map_jpeg(const GainMapResult& images,
                                               const PhotoMetadata& metadata, int quality) {
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  images.gain_map.require_consistent("gain-map JPEG recovery map");
  validate_gain_map_metadata(images.metadata);
  const auto channels = gain_map_channel_count(images.metadata);
  images.base_linear.require_consistent("gain-map JPEG base");
  check_jpeg_dimensions(images.base_linear.width, images.base_linear.height);
  check_jpeg_dimensions(images.gain_map.width, images.gain_map.height);
  if (!images.gain_map.width || !images.gain_map.height ||
      images.base_linear.width % images.gain_map.width ||
      images.base_linear.height % images.gain_map.height ||
      images.base_linear.width / images.gain_map.width != images.base_linear.height / images.gain_map.height)
    throw std::invalid_argument("gain-map JPEG requires an integer image scale");
  if (images.gain_map.channels != channels) {
    throw std::invalid_argument("gain-map JPEG recovery pixels and metadata must have matching channels");
  }
  // A full-resolution gain map exists to put every HDR pixel back where it was
  // (an HDR source's own highlights). Subsampling the base's chroma would throw
  // away half of the colour resolution that map multiplies, which measured on a
  // Sony HLG frame as most of the remaining error at saturated highlight edges.
  // A mathematical map is low-frequency and keeps the smaller 4:2:0 base.
  const bool full_resolution_gain = images.gain_map.width == images.base_linear.width &&
                                     images.gain_map.height == images.base_linear.height;
  auto base_bytes = make_base_jpeg(images.base_linear, metadata, quality,
                                   images.clamp_srgb, full_resolution_gain);
  // The format guidance recommends 85-90 for the recovery map. Keep HDR
  // reconstruction stable even when the caller deliberately lowers base quality.
  auto gain_bytes = make_gain_jpeg(images.gain_map, std::max(85, quality));

  return assemble_gain_map_jpeg(base_bytes, gain_bytes, images.metadata);
}

GainMapJpegEncoding encode_gain_map_jpeg_measured(const GainMapResult& images,
    const PhotoMetadata& metadata, int quality, const FrameLayout* frame) {
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  validate_gain_map_metadata(images.metadata, GainMapWriterProfile::iso_generic);
  images.base_linear.require_consistent("gain-map JPEG base");
  images.gain_map.require_consistent("gain-map JPEG recovery map");
  check_jpeg_dimensions(images.base_linear.width, images.base_linear.height);
  const bool full_resolution = images.base_linear.width == images.gain_map.width &&
      images.base_linear.height == images.gain_map.height;
  auto primary = make_base_jpeg(images.base_linear, metadata, quality, images.clamp_srgb, full_resolution);
  if (!(rational_value(images.metadata.alternate_headroom) > kEpsilon)) {
    // A map declaring no headroom (only the token one) has no HDR to restore:
    // its zero gain stands as packaged, and correcting the base's compression
    // error would only store noise.
    GainMapJpegEncoding out;
    out.bytes = assemble_gain_map_jpeg(primary, make_gain_jpeg(images.gain_map, std::max(85, quality)),
                                       images.metadata);
    out.metadata = images.metadata;
    out.stats = images.stats;
    return out;
  }
  PhotoRenditions pair;
  pair.hdr = reconstruct_gain_map(images.base_linear, images.gain_map, images.metadata,
      rational_value(images.metadata.alternate_headroom));
  (void)decode_jpeg_for_verification(primary.data(), primary.size(), &pair.sdr);
  if (frame) {
    if (frame->width != pair.sdr.width || frame->height != pair.sdr.height)
      throw std::invalid_argument("JPEG frame mask dimensions do not match the base");
    // JPEG recovery corrects the photograph only. The mat remains the decoded
    // SDR primary; no correction in the mat is derived from HDR photo pixels.
    for (std::uint32_t y = 0; y < pair.sdr.height; ++y) {
      check_cancelled();
      for (std::uint32_t x = 0; x < pair.sdr.width; ++x) {
        if (x >= frame->photo.x && x - frame->photo.x < frame->photo.width &&
            y >= frame->photo.y && y - frame->photo.y < frame->photo.height) continue;
        for (unsigned c = 0; c < 3; ++c) pair.hdr.at(x,y,c) = pair.sdr.at(x,y,c);
      }
    }
  }
  pair.stats = images.stats;
  pair.stats.headroom_stops = rational_value(images.metadata.alternate_headroom);
  pair.dual_rendition = true;
  pair.authored_gain_channels = images.gain_map.channels;
  for (unsigned c = 0; c < 3; ++c) {
    const auto channel = gain_map_channel(images.metadata, images.gain_map.channels == 1 ? 0 : c);
    pair.authored_gain_map.base_offset[c] = rational_value(channel.base_offset);
    pair.authored_gain_map.alternate_offset[c] = rational_value(channel.alternate_offset);
  }
  auto corrected = gain_map_from_renditions(std::move(pair), GainMapWriterProfile::iso_generic);
  // Recovery codes contain sharp channel corrections for the lossy primary.
  // Unit quantizers keep those corrections inside the HDR peak/error limits.
  auto gain = make_gain_jpeg(corrected.gain_map, 100);
  GainMapJpegEncoding out;
  out.bytes = assemble_gain_map_jpeg(primary, gain, corrected.metadata);
  out.metadata = std::move(corrected.metadata);
  out.stats = corrected.stats;
  return out;
}

void verify_gain_map_jpeg(const std::vector<std::uint8_t>& bytes) {
  const auto parsed = parse_gain_map_jpeg(bytes);
  // HyperDR writes ISO 21496-1 only. A file that also describes its gain map
  // in Ultra HDR XMP (an Android 15 photo, for instance) is valid elsewhere
  // but is not one of this program's exports.
  if (parsed.has_hdrgm)
    throw std::runtime_error("gain-map JPEG also carries Ultra HDR XMP (hdrgm) gain metadata; "
                             "HyperDR exports carry ISO 21496-1 metadata only");
  if (parsed.has_container_directory)
    throw std::runtime_error("gain-map JPEG carries an XMP Container:Directory; "
                             "HyperDR exports locate the gain map through MPF only");
  validate_gain_map_metadata(parsed.metadata, GainMapWriterProfile::iso_generic);
  bool icc = false;
  for (const auto& app : parsed.app_segments[0]) {
    constexpr char signature[] = "ICC_PROFILE";
    if (app.marker == 0xe2 && app.payload.size() > 14 &&
        std::equal(signature, signature + sizeof(signature), app.payload.begin())) icc = true;
  }
  if (!icc) throw std::runtime_error("gain-map JPEG has no primary ICC profile");
  const auto base = decode_jpeg_for_verification(bytes.data(), parsed.primary_size);
  const auto gain = decode_jpeg_for_verification(bytes.data() + parsed.gain_offset, parsed.gain_size);
  if (base[2] != 3 || gain[2] != gain_map_channel_count(parsed.metadata) ||
      !gain[0] || !gain[1] || base[0] % gain[0] || base[1] % gain[1] ||
      base[0] / gain[0] != base[1] / gain[1])
    throw std::runtime_error("gain-map JPEG raster dimensions/channels do not match metadata");
}

void verify_gain_map_jpeg(const std::filesystem::path& input) {
  verify_gain_map_jpeg(read_binary_file(input));
}

}  // namespace hyperdr

#include "hyperdr/app/package.hpp"

#include "hyperdr/app/settings.hpp"
#include "hyperdr/codec/avif_grid.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/rendition.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

// The gain codebook is the one every writer already uses: normalized code,
// gathered gamma, then a per-pixel 8-bit code. Keeping the parameters here
// means the report can state what was written instead of what was requested.
struct QuantizedGain {
  GainMapMetadata metadata;
  FloatImage codes;
  float gain_min{};
  float gain_max{};
  float gamma{1.0F};
  float alternate_headroom{};
  std::uint64_t clipped_samples{};
};

bool finite_extremes(const FloatImage& image, float& low, float& high) {
  std::vector<float> row_low(image.height, 0.0F), row_high(image.height, 0.0F);
  std::vector<std::uint8_t> row_bad(image.height, 0);
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    float minimum = 0.0F, maximum = 0.0F;
    bool bad = false;
    const auto begin = image.pixels.begin() + static_cast<std::size_t>(y) * image.width * image.channels;
    const auto end = begin + static_cast<std::size_t>(image.width) * image.channels;
    for (auto sample = begin; sample != end; ++sample) {
      if (!std::isfinite(*sample)) { bad = true; break; }
      minimum = std::min(minimum, *sample);
      maximum = std::max(maximum, *sample);
    }
    row_low[y] = minimum; row_high[y] = maximum; row_bad[y] = bad ? 1 : 0;
  });
  low = *std::min_element(row_low.begin(), row_low.end());
  high = *std::max_element(row_high.begin(), row_high.end());
  return std::none_of(row_bad.begin(), row_bad.end(), [](std::uint8_t bad) { return bad != 0; });
}

// Copies a caller plane into the pipeline's own image, then checks that every
// sample is a number. A NaN reaching a codec becomes an unreadable file that
// the write-after check catches only after the work is done. The extremes come
// back from the same pass, because the gain codebook needs them.
FloatImage copy_plane(const PackagePlane& plane, const char* what,
                      float* low_out = nullptr, float* high_out = nullptr) {
  if (plane.data == nullptr) throw std::invalid_argument(std::string(what) + " plane data is null");
  if (plane.width == 0 || plane.height == 0 || plane.channels == 0)
    throw std::invalid_argument(std::string(what) + " plane has an empty dimension");
  FloatImage image(plane.width, plane.height, plane.channels);
  const auto tight = static_cast<std::size_t>(plane.width) * plane.channels * sizeof(float);
  const auto stride = plane.row_bytes ? plane.row_bytes : tight;
  if (stride < tight)
    throw std::invalid_argument(std::string(what) + " row_bytes is shorter than one row");
  if (plane.size != 0 && plane.size < stride * plane.height)
    throw std::invalid_argument(std::string(what) + " buffer is shorter than its rows");
  const auto* bytes = reinterpret_cast<const std::uint8_t*>(plane.data);
  parallel_for_rows(plane.height, [&](std::uint32_t y) {
    std::memcpy(image.pixels.data() + static_cast<std::size_t>(y) * plane.width * plane.channels,
                bytes + static_cast<std::size_t>(y) * stride, tight);
  });
  float low = 0.0F, high = 0.0F;
  if (!finite_extremes(image, low, high))
    throw std::invalid_argument(std::string(what) + " plane contains a non-finite sample");
  if (low_out) *low_out = low;
  if (high_out) *high_out = high;
  return image;
}

// Offsets are small (order 1e-5) and near-black reconstruction depends on them,
// so keep the extra (2^24) precision the converter's own packager uses rather
// than the default 1e-5 grid, which would round an authored offset to zero.
Rational offset_rational(float value) {
  if (value == 1.0F / 64.0F) return {1, 64};
  return rational_from_float(value, 1U << 24);
}

void validate_offsets(const PackageGain& gain, std::uint32_t channels) {
  for (std::uint32_t c = 0; c < channels; ++c) {
    if (!std::isfinite(gain.base_offset[c]) || !std::isfinite(gain.alternate_offset[c]))
      throw std::invalid_argument("gain offsets must be finite");
    if (std::abs(gain.base_offset[c]) > 64.0F || std::abs(gain.alternate_offset[c]) > 64.0F)
      throw std::invalid_argument("gain offsets must be within [-64, 64]");
  }
  if (!std::isfinite(gain.base_headroom) || !std::isfinite(gain.alternate_headroom))
    throw std::invalid_argument("gain headroom must be finite");
  if (gain.base_headroom < 0.0F || gain.alternate_headroom < 0.0F)
    throw std::invalid_argument("gain headroom must not be negative");
}

// Quantizes the caller's log2-stop plane into the 8-bit codes and metadata the
// writers store. `apple_strict` is ISO 21496-1's Apple form: one channel, and
// alternate headroom equal to the map's largest gain.
QuantizedGain quantize_gain(const PackageGain& gain, bool apple_strict) {
  QuantizedGain out;
  float low = 0.0F, high = 0.0F;
  FloatImage grid = copy_plane(gain.plane, "gain", &low, &high);
  if (grid.channels != 1 && grid.channels != 3)
    throw std::invalid_argument("gain plane must have one or three channels");
  const auto channels = grid.channels;
  validate_offsets(gain, channels);
  if (apple_strict && channels != 1)
    throw UnsupportedFormat(
        "the adaptive format writes ISO 21496-1's single-channel gain map; "
        "a three-channel gain map needs iso-gainmap-jpeg or a BT.2100 format");
  if (apple_strict && gain.base_headroom != 0.0F)
    throw UnsupportedFormat("the adaptive format writes a base headroom of 0 stops");
  if (!apple_strict && gain.alternate_headroom > 0.0F &&
      gain.alternate_headroom < gain.base_headroom)
    throw std::invalid_argument("alternate headroom is below base headroom");

  if (apple_strict) {
    const auto negative = static_cast<std::uint64_t>(
        std::count_if(grid.pixels.begin(), grid.pixels.end(), [](float value) { return value < 0.0F; }));
    out.clipped_samples = negative;
    for (float& value : grid.pixels) value = std::max(0.0F, value);
    low = 0.0F;
    // A positive declared alternate headroom is the capacity the file
    // advertises, so the codes are laid out over it. The content's own maximum
    // is the fallback, and it must fit: the adaptive form stores no gain above
    // the headroom it declares.
    const float capacity = gain.alternate_headroom > 0.0F ? gain.alternate_headroom : high;
    if (high > capacity + 1.0e-3F)
      throw UnsupportedFormat(
          "gain reaches " + json::number_text(high) + " stops but the declared alternate headroom is " +
          json::number_text(capacity) + " stops; the adaptive format stores no gain above its headroom");
    high = capacity;
  } else if (gain.alternate_headroom > 0.0F) {
    out.alternate_headroom = gain.alternate_headroom;
  }

  auto& metadata = out.metadata;
  metadata.gain_min = rational_from_float(low);
  metadata.gain_max = rational_from_float(high);
  out.gain_min = rational_value(metadata.gain_min);
  out.gain_max = rational_value(metadata.gain_max);
  const float range = out.gain_max - out.gain_min;

  // Gamma is chosen from the distribution, exactly as every writer does, then
  // read back from its stored rational so the codes match the file's metadata.
  std::vector<float> normalized(grid.pixels.size());
  for (std::size_t i = 0; i < grid.pixels.size(); ++i)
    normalized[i] = range > kEpsilon
                        ? clamp_finite((grid.pixels[i] - out.gain_min) / range, 0.0F, 1.0F) : 0.0F;
  metadata.gamma = rational_from_float(range > kEpsilon ? choose_gain_gamma(normalized) : 1.0F);
  out.gamma = rational_value(metadata.gamma);

  out.codes = FloatImage(grid.width, grid.height, channels);
  parallel_for_rows(grid.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < grid.width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * grid.width + x;
      for (std::uint32_t c = 0; c < channels; ++c) {
        const auto index = pixel * channels + c;
        const float encoded = encode_gain_code(normalized[index], out.gamma);
        out.codes.pixels[index] = quantize_gain_code_dithered(encoded, x, y);
      }
    }
  });

  metadata.base_offset = offset_rational(gain.base_offset[0]);
  metadata.alternate_offset = offset_rational(gain.alternate_offset[0]);
  metadata.base_headroom = rational_from_float(gain.base_headroom);
  // An ISO-generic pair with no declared capacity advertises the gain's own
  // maximum, which is what the file can actually show.
  if (!apple_strict && out.alternate_headroom <= 0.0F) out.alternate_headroom = high;
  metadata.alternate_headroom = rational_from_float(apple_strict ? high : out.alternate_headroom);
  if (channels == 3) {
    const auto channel = gain_map_channel(metadata, 0);
    metadata.flags |= 0x80;
    metadata.channels.assign(3, channel);
    for (std::uint32_t c = 0; c < 3; ++c) {
      metadata.channels[c].base_offset = offset_rational(gain.base_offset[c]);
      metadata.channels[c].alternate_offset = offset_rational(gain.alternate_offset[c]);
    }
  }
  out.alternate_headroom = rational_value(metadata.alternate_headroom);
  validate_gain_map_metadata(metadata, apple_strict ? GainMapWriterProfile::apple_strict
                                                    : GainMapWriterProfile::iso_generic);
  return out;
}

ColorGamut resolved_gamut(const PackageRequest& request) {
  return request.gamut.value_or(request.encoding == OutputEncoding::SdrJpeg
                                    ? ColorGamut::kSrgb : ColorGamut::kDisplayP3);
}

std::string verification_name(OutputEncoding encoding) {
  if (encoding == OutputEncoding::SdrJpeg) return "sdr-jpeg";
  if (encoding == OutputEncoding::SdrTiff) return "sdr-tiff";
  if (encoding == OutputEncoding::IsoGainMapJpeg) return "iso-gainmap-jpeg";
  if (is_avif_encoding(encoding)) return "avif";
  return encoding == OutputEncoding::Adaptive ? "heic-gain-map" : "heic-bt2100";
}

}  // namespace

std::string package_image(const PackageRequest& request) {
  if (request.sdr == nullptr) throw std::invalid_argument("the SDR base plane is required");
  if (request.output.empty()) throw std::invalid_argument("the output path is required");
  if (request.quality < 0 || request.quality > 100)
    throw std::invalid_argument("quality must be in [0,100]");
  // Only the Adaptive base selects a bit depth; convert rejects the others too
  // rather than silently ignoring the setting.
  if (request.encoding == OutputEncoding::Adaptive
          ? (request.depth != 8 && request.depth != 10)
          : request.depth != 8)
    throw std::invalid_argument("depth must be 8 or 10");

  const auto encoding = request.encoding;
  const bool gain_map_output = is_gain_map_encoding(encoding);
  const bool bt2100_output = is_bt2100_encoding(encoding);
  if (gain_map_output && request.gain == nullptr)
    throw UnsupportedFormat(std::string(hdr_encoding_name(encoding)) +
                            " needs a gain plane; this request supplied only an SDR base");
  if (bt2100_output && request.gain == nullptr)
    throw UnsupportedFormat(std::string(hdr_encoding_name(encoding)) +
                            " has no HDR rendition without a gain plane");

  FloatImage base = copy_plane(*request.sdr, "SDR base");
  if (base.channels != 3)
    throw std::invalid_argument("the SDR base plane must have three channels");
  // A gain plane describes the same pixels: this version writes the codes 1:1
  // and does not resample a grid onto the base.
  if (request.gain != nullptr) {
    const auto& plane = request.gain->plane;
    if (plane.width != base.width || plane.height != base.height)
      throw std::invalid_argument("the gain plane must have the base's pixel dimensions");
    if (!request.gain->working_gamut.empty() && request.gain->working_gamut != "display-p3")
      throw UnsupportedFormat("gain working gamut \"" + request.gain->working_gamut +
                              "\" is not supported; the base is Display P3 and no writer converts a grid");
  }

  // Refuse a canvas the encoder (or the verifier) cannot open, before any
  // pixels are encoded: a JPEG past 65500 per side has no representation, and
  // libavif cannot decode a canvas past its own limits, so a file written there
  // could never pass its own check.
  if ((encoding == OutputEncoding::SdrJpeg || encoding == OutputEncoding::IsoGainMapJpeg) &&
      (base.width > 65500 || base.height > 65500))
    throw ExportDimensionLimit(base.width, base.height);
  if (is_avif_encoding(encoding) && !avif_canvas_decodable(base.width, base.height))
    throw ExportDimensionLimit::avif(base.width, base.height);

  check_cancelled();
  std::optional<QuantizedGain> gain;
  if (request.gain != nullptr && (gain_map_output || bt2100_output)) {
    gain = quantize_gain(*request.gain, encoding == OutputEncoding::Adaptive);
    // HLG's signal only carries about 2.3 stops above diffuse white; a pair
    // that reaches higher would be compressed into that range while the file's
    // metadata still claimed the higher headroom. Convert refuses it too.
    validate_encoding_headroom(encoding, gain->alternate_headroom);
  }

  PhotoMetadata photo;
  if (request.exif != nullptr && request.exif_size != 0) photo = read_exif(request.exif, request.exif_size).metadata;
  // The planes are expected upright, so the tag must not rotate them again.
  photo.orientation = 1;

  check_cancelled();
  std::vector<std::uint8_t> bytes;
  switch (encoding) {
    case OutputEncoding::SdrJpeg: {
      const auto gamut = resolved_gamut(request);
      if (gamut == ColorGamut::kSrgb) fit_sdr_to_srgb(base);
      bytes = encode_sdr_jpeg(base, photo, request.quality, gamut);
      break;
    }
    case OutputEncoding::SdrTiff: {
      const auto gamut = resolved_gamut(request);
      if (gamut == ColorGamut::kSrgb) fit_sdr_to_srgb(base);
      bytes = encode_sdr_tiff(base, photo, gamut);
      break;
    }
    case OutputEncoding::Adaptive:
    case OutputEncoding::IsoGainMapJpeg: {
      GainMapResult images;
      images.base_linear = std::move(base);
      images.gain_map = std::move(gain->codes);
      images.metadata = gain->metadata;
      images.headroom_stops = gain->alternate_headroom;
      bytes = encoding == OutputEncoding::Adaptive
                  ? encode_adaptive_heic(images, photo, request.quality, request.depth, request.hevc_preset)
                  : encode_gain_map_jpeg(std::move(images), photo, request.quality);
      break;
    }
    case OutputEncoding::Pq:
    case OutputEncoding::Hlg:
    case OutputEncoding::AvifPq:
    case OutputEncoding::AvifHlg: {
      // The pair reconstructs the HDR rendition this format stores, at the
      // headroom it declares, so the HDR pixels are exactly what the same gain
      // map would decode to.
      PhotoRenditions renditions;
      renditions.sdr = std::move(base);
      renditions.hdr = reconstruct_gain_map(renditions.sdr, gain->codes, gain->metadata,
                                           gain->alternate_headroom);
      renditions.stats.headroom_stops = gain->alternate_headroom;
      bytes = is_avif_encoding(encoding)
                  ? encode_avif(renditions, photo, request.quality, encoding)
                  : encode_hdr_heic(renditions, photo, request.quality, encoding, request.hevc_preset);
      break;
    }
  }

  check_cancelled();
  if (request.verify) {
    verify_encoded_output(bytes, encoding);
    check_cancelled();
  }
  write_binary_file_atomic(request.output, bytes, request.overwrite);

  json::Writer writer;
  writer.begin_object().member("schema", "hyperdr.package/v1")
      .member("output", path_utf8(request.output))
      .member("format", hdr_encoding_name(encoding))
      .member("width", request.sdr->width)
      .member("height", request.sdr->height)
      .member("bytes", bytes.size())
      .member("verified", request.verify)
      .member("verification", request.verify ? verification_name(encoding) : "skipped")
      .begin_object("metadata")
      .member("exif", request.exif != nullptr && request.exif_size != 0)
      // The colour space the written samples are in: a BT.2100 rendition is
      // Rec.2020 and carries no ICC profile of its own.
      .member("icc", bt2100_output ? "rec2020"
                         : is_sdr_encoding(encoding) && resolved_gamut(request) == ColorGamut::kSrgb
                               ? "srgb" : "display-p3")
      .end_object();
  if (gain.has_value() && (gain_map_output || bt2100_output)) {
    writer.begin_object("gain").member("stored", gain_map_output)
        .member("channels", gain->codes.channels)
        .member("width", gain->codes.width).member("height", gain->codes.height)
        .member("gainMin", gain->gain_min).member("gainMax", gain->gain_max)
        .member("gamma", gain->gamma)
        .begin_array("baseOffsets");
    for (std::uint32_t c = 0; c < gain->codes.channels; ++c)
      writer.element(rational_value(gain_map_channel(gain->metadata, c).base_offset));
    writer.end_array().begin_array("alternateOffsets");
    for (std::uint32_t c = 0; c < gain->codes.channels; ++c)
      writer.element(rational_value(gain_map_channel(gain->metadata, c).alternate_offset));
    writer.end_array()
        .member("baseHeadroom", rational_value(gain->metadata.base_headroom))
        .member("alternateHeadroom", rational_value(gain->metadata.alternate_headroom))
        .member("clippedSamples", gain->clipped_samples)
        .end_object();
  } else {
    writer.null_member("gain");
  }
  return writer.end_object().take() + '\n';
}

}  // namespace hyperdr

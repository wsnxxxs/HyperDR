#include "hyperdr/app/package.hpp"

#include "hyperdr/app/settings.hpp"
#include "hyperdr/codec/avif_grid.hpp"
#include "hyperdr/codec/availability.hpp"
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
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

#include <unistd.h>

namespace hyperdr {
namespace {

// A framed map's mat is written as exactly zero gain; this is the residue a
// caller's own float arithmetic may leave on it, in log2 stops (about 1/14000
// of a stop). Anything larger is a real gain and gets its own code.
constexpr float kFrameZeroTolerance = 1.0e-4F;

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
  // The code that carries zero stops; set only for a framed pair, where it is
  // an integer code that decodes to exactly no gain.
  float zero_code{};
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

void validate_offsets(const PackageGain& gain, std::uint32_t channels, bool presentation_frame) {
  for (std::uint32_t c = 0; c < channels; ++c) {
    if (!std::isfinite(gain.base_offset[c]) || !std::isfinite(gain.alternate_offset[c]))
      throw std::invalid_argument("gain offsets must be finite");
    if (std::abs(gain.base_offset[c]) > 64.0F || std::abs(gain.alternate_offset[c]) > 64.0F)
      throw std::invalid_argument("gain offsets must be within [-64, 64]");
    // E5: the mat is reproduced by the zero-gain code alone, so both renditions
    // must agree there. An affine pair whose offsets differ would paint the
    // mat by (base_offset - alternate_offset) at every zero code.
    if (presentation_frame && gain.base_offset[c] != gain.alternate_offset[c])
      throw UnsupportedFormat(
          "a framed pair must use the same base and alternate offsets; "
          "differing offsets give the mat its own gain");
  }
  if (!std::isfinite(gain.base_headroom) || !std::isfinite(gain.alternate_headroom))
    throw std::invalid_argument("gain headroom must be finite");
  if (gain.base_headroom < 0.0F || gain.alternate_headroom < 0.0F)
    throw std::invalid_argument("gain headroom must not be negative");
}

// Quantizes the caller's log2-stop plane into the 8-bit codes and metadata the
// writers store. `apple_strict` is ISO 21496-1's Apple form: one channel, and
// alternate headroom equal to the map's largest gain. `presentation_frame`
// applies E5 to the codebook: the mat outside the photograph must decode to no
// gain at all, which needs an exact integer zero-gain code at gamma 1.
QuantizedGain quantize_gain(const PackageGain& gain, bool apple_strict, bool presentation_frame) {
  QuantizedGain out;
  float low = 0.0F, high = 0.0F;
  FloatImage grid = copy_plane(gain.plane, "gain", &low, &high);
  if (grid.channels != 1 && grid.channels != 3)
    throw std::invalid_argument("gain plane must have one or three channels");
  const auto channels = grid.channels;
  validate_offsets(gain, channels, presentation_frame);
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
  // A framed canvas keeps zero on an integer code, so the mat's own code reads
  // back as exactly no gain instead of the two codes that bracket it.
  if (presentation_frame) align_zero_gain(metadata.gain_min, metadata.gain_max);
  out.gain_min = rational_value(metadata.gain_min);
  out.gain_max = rational_value(metadata.gain_max);
  const float range = out.gain_max - out.gain_min;

  // Gamma is chosen from the distribution, exactly as every writer does, then
  // read back from its stored rational so the codes match the file's metadata.
  // A framed map stays at gamma 1: aligning zero is only worth it if nothing
  // else moves the code that represents it.
  std::vector<float> normalized(grid.pixels.size());
  for (std::size_t i = 0; i < grid.pixels.size(); ++i)
    normalized[i] = range > kEpsilon
                        ? clamp_finite((grid.pixels[i] - out.gain_min) / range, 0.0F, 1.0F) : 0.0F;
  metadata.gamma = rational_from_float(
      presentation_frame ? 1.0F : (range > kEpsilon ? choose_gain_gamma(normalized) : 1.0F));
  out.gamma = rational_value(metadata.gamma);

  // The reference point the frame needs: the code that carries zero stops, and
  // the mat's samples snapped onto it. Dithering is what keeps a photograph's
  // shadows from banding, and it is exactly what would move the mat's code.
  const float zero_code = std::round(clamp_finite(
      range > kEpsilon ? (0.0F - out.gain_min) / range : 0.0F, 0.0F, 1.0F) * 255.0F) / 255.0F;
  out.codes = FloatImage(grid.width, grid.height, channels);
  parallel_for_rows(grid.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < grid.width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * grid.width + x;
      for (std::uint32_t c = 0; c < channels; ++c) {
        const auto index = pixel * channels + c;
        const float encoded = encode_gain_code(normalized[index], out.gamma);
        out.codes.pixels[index] = !presentation_frame
            ? quantize_gain_code_dithered(encoded, x, y)
            : std::abs(grid.pixels[index]) <= kFrameZeroTolerance
                  ? zero_code : std::round(encoded * 255.0F) / 255.0F;
      }
    }
  });
  if (presentation_frame && std::abs(out.gain_min + range * zero_code) > 1.0e-6F)
    throw std::logic_error("the framed gain codebook did not keep an exact zero code");
  out.zero_code = zero_code;

  metadata.base_offset = offset_rational(gain.base_offset[0]);
  metadata.alternate_offset = offset_rational(gain.alternate_offset[0]);
  metadata.base_headroom = rational_from_float(gain.base_headroom);
  // An ISO-generic pair with no declared capacity advertises the gain's own
  // maximum, which is what the file can actually show.
  if (!apple_strict && out.alternate_headroom <= 0.0F) out.alternate_headroom = high;
  metadata.alternate_headroom = rational_from_float(apple_strict ? out.gain_max : out.alternate_headroom);
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


QuantizedGain stream_codebook(const PackageGain& gain,bool apple_strict,bool presentation_frame,
    float low,float high,std::span<const float> samples,std::uint64_t negative) {
  QuantizedGain out;
  const auto channels = gain.plane.channels;
  validate_offsets(gain, channels, presentation_frame);
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
    out.clipped_samples = negative;
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
  // A framed canvas keeps zero on an integer code, so the mat's own code reads
  // back as exactly no gain instead of the two codes that bracket it.
  if (presentation_frame) align_zero_gain(metadata.gain_min, metadata.gain_max);
  out.gain_min = rational_value(metadata.gain_min);
  out.gain_max = rational_value(metadata.gain_max);
  const float range = out.gain_max - out.gain_min;

  // Gamma is chosen from the distribution, exactly as every writer does, then
  // read back from its stored rational so the codes match the file's metadata.
  // A framed map stays at gamma 1: aligning zero is only worth it if nothing
  // else moves the code that represents it.
  std::vector<float> normalized(samples.size());
  for (std::size_t i = 0; i < samples.size(); ++i)
    normalized[i] = range > kEpsilon
                        ? clamp_finite(((apple_strict ? std::max(0.f,samples[i]) : samples[i]) - out.gain_min) / range, 0.0F, 1.0F) : 0.0F;
  metadata.gamma = rational_from_float(
      presentation_frame ? 1.0F : (range > kEpsilon ? choose_gain_gamma(normalized) : 1.0F));
  out.gamma = rational_value(metadata.gamma);

  // The reference point the frame needs: the code that carries zero stops, and
  // the mat's samples snapped onto it. Dithering is what keeps a photograph's
  // shadows from banding, and it is exactly what would move the mat's code.
  const float zero_code = std::round(clamp_finite(
      range > kEpsilon ? (0.0F - out.gain_min) / range : 0.0F, 0.0F, 1.0F) * 255.0F) / 255.0F;
  out.codes.width=gain.plane.width; out.codes.height=gain.plane.height; out.codes.channels=channels;
  if (presentation_frame && std::abs(out.gain_min + range * zero_code) > 1.0e-6F)
    throw std::logic_error("the framed gain codebook did not keep an exact zero code");
  out.zero_code = zero_code;

  metadata.base_offset = offset_rational(gain.base_offset[0]);
  metadata.alternate_offset = offset_rational(gain.alternate_offset[0]);
  metadata.base_headroom = rational_from_float(gain.base_headroom);
  // An ISO-generic pair with no declared capacity advertises the gain's own
  // maximum, which is what the file can actually show.
  if (!apple_strict && out.alternate_headroom <= 0.0F) out.alternate_headroom = high;
  metadata.alternate_headroom = rational_from_float(apple_strict ? out.gain_max : out.alternate_headroom);
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

// E5 read back rather than assumed: the mat outside the photograph must carry no
// gain, and the only way to know is to decode the file that was just written --
// the staging file, before anything is published to the caller's path.
//
// Zero stored gain means the two renditions are the same pixel, whatever the
// offsets are: a framed pair keeps base and alternate offsets equal, so the
// reconstruction collapses to the base itself. Comparing the renditions
// directly also keeps a negative offset pair honest -- with base + offset below
// zero, any arithmetic that goes through the offsets sees a gain that is not
// there.
//
// One coding block next to the photograph is left out: an 8x8 JPEG or HEVC gain
// block that straddles the photo's edge rings into the mat, which is a property
// of the codec rather than of the codes, and E5's promise is about the gain the
// writer stores (checked at the codebook before encoding). A mat narrower than
// that margin has nothing left to read back.
constexpr std::uint32_t kMatReadbackMargin = 8;

// The same E5 rule at the codebook, before anything is encoded: every sample the
// caller did not place inside the photograph is the zero code.
std::uint64_t mat_samples_carrying_gain(const QuantizedGain& gain, const FrameRect& photo) {
  std::uint64_t count = 0;
  for (std::uint32_t y = 0; y < gain.codes.height; ++y) {
    const bool in_photo_rows = y >= photo.y && y < photo.y + photo.height;
    for (std::uint32_t x = 0; x < gain.codes.width; ++x) {
      if (in_photo_rows && x >= photo.x && x < photo.x + photo.width) continue;
      const auto pixel = (static_cast<std::size_t>(y) * gain.codes.width + x) * gain.codes.channels;
      for (std::uint32_t c = 0; c < gain.codes.channels; ++c)
        if (gain.codes.pixels[pixel + c] != gain.zero_code) ++count;
    }
  }
  return count;
}

void verify_framed_mat(const PackageRequest& request, const std::filesystem::path& staged) {
  const auto& photo = *request.frame_photo;
  const auto width = request.sdr->width, height = request.sdr->height;
  const auto decoded = decode_image(staged);
  if (!decoded.authored_sdr)
    throw std::runtime_error("the framed package did not read back as a base plus gain map");
  const auto& base = *decoded.authored_sdr;
  const auto& alternate = decoded.linear_p3;
  if (base.width != width || base.height != height || alternate.width != width ||
      alternate.height != height)
    throw std::runtime_error("the framed package read back at a different size than it was given");
  std::uint64_t failures = 0, checked = 0;
  float worst = 0.0F;
  std::uint32_t worst_x = 0, worst_y = 0;
  const auto check = [&](std::uint32_t x, std::uint32_t y) {
    const auto pixel = (static_cast<std::size_t>(y) * width + x) * 3;
    for (std::uint32_t c = 0; c < 3; ++c) {
      const float sdr = base.pixels[pixel + c];
      const float difference = std::abs(alternate.pixels[pixel + c] - sdr);
      ++checked;
      if (difference <= 1.0e-5F * (1.0F + std::abs(sdr))) continue;
      ++failures;
      if (difference > worst) { worst = difference; worst_x = x; worst_y = y; }
    }
  };
  // One coding block of slack on every side of the photograph, clipped to the
  // canvas so a photograph at the edge is handled the same way.
  const auto near_left = photo.x > kMatReadbackMargin ? photo.x - kMatReadbackMargin : 0;
  const auto near_top = photo.y > kMatReadbackMargin ? photo.y - kMatReadbackMargin : 0;
  const auto near_right = std::min(width, photo.x + photo.width + kMatReadbackMargin);
  const auto near_bottom = std::min(height, photo.y + photo.height + kMatReadbackMargin);
  for (std::uint32_t y = 0; y < height; ++y) {
    check_cancelled();
    const bool in_photo_rows = y >= photo.y && y < photo.y + photo.height;
    for (std::uint32_t x = 0; x < width; ++x) {
      if (in_photo_rows && x >= photo.x && x < photo.x + photo.width) continue;
      if (x < near_left || x >= near_right || y < near_top || y >= near_bottom) check(x, y);
    }
  }
  if (checked == 0) return;
  if (failures != 0)
    throw std::runtime_error(
        "the framed mat carries gain: " + std::to_string(failures) + " samples, worst at " +
        std::to_string(worst_x) + "," + std::to_string(worst_y) + " (" +
        json::number_text(worst) + " linear)");
}

// A framed export is checked before it is published: the bytes go to a staging
// file beside the destination (so publishing is a rename on one volume), the
// readback decodes that file, and only then does the caller's path change. A
// cancelled or failing check must not be able to destroy the file the caller
// already had there, which a check after the rename cannot promise.
//
// The staging file is created exclusively: its name is a guess, and a file that
// already answers to it belongs to somebody else, so neither writing over it nor
// deleting it afterwards is ours to do. The destructor therefore only ever
// removes a file this call created.
struct StagingFile {
  StagingFile() = default;
  explicit StagingFile(std::filesystem::path created) : path(std::move(created)) {}
  StagingFile(const StagingFile&) = delete;
  StagingFile& operator=(const StagingFile&) = delete;
  StagingFile(StagingFile&&) = delete;
  StagingFile& operator=(StagingFile&&) = delete;
  ~StagingFile() {
    if (!path.empty()) {
      std::error_code ignored;
      std::filesystem::remove(path, ignored);
    }
  }
  std::filesystem::path path;
};

std::filesystem::path reserve_staging_beside(const std::filesystem::path& output) {
  static std::atomic<std::uint64_t> sequence{0};
  const std::string base =
      output.filename().native() + ".reading." + std::to_string(::getpid()) + ".";
  for (unsigned attempt = 0; attempt < 256; ++attempt) {
    const std::string name =
        base + std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
    auto candidate = output.has_parent_path() ? output.parent_path() / name : std::filesystem::path(name);
    const int file = ::open(candidate.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (file >= 0) {
      ::close(file);
      return candidate;
    }
    if (errno != EEXIST)
      throw std::runtime_error("cannot create a staging file beside the output");
  }
  throw std::runtime_error("cannot find a free staging name beside the output");
}

std::string verification_name(OutputEncoding encoding) {
  if (encoding == OutputEncoding::SdrJpeg) return "sdr-jpeg";
  if (encoding == OutputEncoding::SdrTiff) return "sdr-tiff";
  if (encoding == OutputEncoding::IsoGainMapJpeg) return "iso-gainmap-jpeg";
  if (is_avif_encoding(encoding)) return "avif";
  return encoding == OutputEncoding::Adaptive ? "heic-gain-map" : "heic-bt2100";
}

std::string package_report(const PackageRequest& request,const std::optional<QuantizedGain>& gain,std::uint64_t byte_count) {
  const auto encoding=request.encoding;
  const bool bt2100_output=is_bt2100_encoding(encoding), gain_map_output=is_gain_map_encoding(encoding);
  json::Writer writer;
  writer.begin_object().member("schema", "hyperdr.package/v1")
      .member("output", path_utf8(request.output))
      .member("format", hdr_encoding_name(encoding))
      .member("width", request.sdr->width)
      .member("height", request.sdr->height)
      .member("bytes", byte_count)
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
  // A frame intention is about a canvas the caller already composited, and the
  // mat readback needs to know where the photograph sits in it.
  if (request.frame_photo && !request.presentation_frame)
    throw std::invalid_argument("a frame photograph rectangle needs presentation_frame");
  if (request.frame_photo && request.gain == nullptr)
    throw std::invalid_argument("a frame photograph rectangle needs the gain plane it applies to");
  if (request.frame_photo && !gain_map_output)
    throw std::invalid_argument(
        "the frame mat readback needs a format that stores the gain map it checks");
  if (request.frame_photo) {
    const auto& photo = *request.frame_photo;
    if (photo.width == 0 || photo.height == 0 || photo.x > base.width || photo.y > base.height ||
        photo.width > base.width - photo.x || photo.height > base.height - photo.y)
      throw std::invalid_argument("the frame photograph rectangle must lie inside the canvas");
  }
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
    gain = quantize_gain(*request.gain, encoding == OutputEncoding::Adaptive,
                         request.presentation_frame);
    // E5 at the codebook, before anything is encoded: whatever the caller left
    // outside the photograph must be the zero code.
    if (request.frame_photo) {
      if (const auto samples = mat_samples_carrying_gain(*gain, *request.frame_photo))
        throw std::runtime_error("the framed mat carries gain at " + std::to_string(samples) +
                                 " coded samples; the photograph rectangle does not cover it");
    }
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
      // Tells a gain-map JPEG to store its gain plane losslessly (quality 100),
      // so a framed mat's zero code cannot be moved by quantizing it.
      images.presentation_frame = request.presentation_frame;
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
  check_cancelled();
  // A framed export is verified on a staging copy, so the readback cannot run
  // after the caller's file has already been replaced.
  std::optional<StagingFile> staging;
  if (request.frame_photo) staging.emplace(reserve_staging_beside(request.output));
  write_binary_file_atomic(staging ? staging->path : request.output, bytes,
                           staging ? true : request.overwrite);
  if (staging) {
    // A file that fails the mat check is never published: the staging copy is
    // removed by its owner and the destination keeps whatever it had.
    verify_framed_mat(request, staging->path);
    write_binary_file_atomic(request.output, bytes, request.overwrite);
  }

  return package_report(request,gain,bytes.size());
}

bool package_rows_supported(OutputEncoding encoding) {
  // libavif's current grid API keeps every YUV cell alive through AddImageGrid.
  return kCodecsAvailable && !is_avif_encoding(encoding);
}

std::string package_image_rows(const PackageRequest& request,std::uint32_t rows,const PackageRows& read) {
  check_cancelled();
  if(!package_rows_supported(request.encoding)) throw UnsupportedFormat("incremental writing is unavailable for this format/build; use whole-plane packaging");
  if(!read || rows==0 || rows>4096 || !request.sdr || request.output.empty())
    throw std::invalid_argument("streaming package needs dimensions, output, reader and 1..4096 rows");
  const auto width=request.sdr->width,height=request.sdr->height;
  const auto channels=request.gain?request.gain->plane.channels:0;
  const bool needs_gain=is_gain_map_encoding(request.encoding)||is_bt2100_encoding(request.encoding);
  if(!width||!height||request.sdr->channels!=3)throw std::invalid_argument("streaming base must be nonempty RGB");
  if(request.quality<0||request.quality>100 || (request.encoding==OutputEncoding::Adaptive?
      (request.depth!=8&&request.depth!=10):request.depth!=8))throw std::invalid_argument("invalid package quality or depth");
  if(needs_gain&&!request.gain)throw UnsupportedFormat("HDR packaging needs a gain plane");
  if(request.gain) {
    if((channels!=1&&channels!=3)||request.gain->plane.width!=width||request.gain->plane.height!=height)
      throw std::invalid_argument("streaming gain must match base dimensions, with 1 or 3 channels");
    if(!request.gain->working_gamut.empty()&&request.gain->working_gamut!="display-p3")throw UnsupportedFormat("gain working gamut must be display-p3");
    validate_offsets(*request.gain,channels,request.presentation_frame);
  }
  if((request.encoding==OutputEncoding::SdrJpeg||request.encoding==OutputEncoding::IsoGainMapJpeg)&&(width>65500||height>65500))throw ExportDimensionLimit(width,height);
  if(request.frame_photo) {
    const auto& f=*request.frame_photo;
    if(!request.presentation_frame||!is_gain_map_encoding(request.encoding)||!request.gain ||
       !f.width||!f.height||f.x>width||f.y>height||f.width>width-f.x||f.height>height-f.y)
      throw std::invalid_argument("frame photograph rectangle must lie inside a framed gain-map canvas");
  }
  const auto stride=std::size_t(width)*3,gstride=std::size_t(width)*channels;
  if(stride>std::numeric_limits<std::size_t>::max()/std::min(rows,height)/sizeof(float))throw std::invalid_argument("streaming band dimensions overflow");
  std::vector<float> base(stride*std::min(rows,height)),grid(gstride*std::min(rows,height));
  unsigned cached=height;
  auto fetch=[&](unsigned y) {
    const auto first=(y/rows)*rows;
    if(cached==first)return;
    check_cancelled();const auto count=std::min(rows,height-first);
    read(first,count,std::span(base).first(stride*count),std::span(grid).first(gstride*count));
    check_cancelled();
    for(const auto v:std::span(base).first(stride*count))if(!std::isfinite(v))throw std::invalid_argument("SDR base contains a non-finite sample");
    for(const auto v:std::span(grid).first(gstride*count))if(!std::isfinite(v))throw std::invalid_argument("gain contains a non-finite sample");
    cached=first;
  };
  std::optional<QuantizedGain> gain;
  if(needs_gain) {
    const std::uint64_t total=std::uint64_t(width)*height*channels;
    const auto count=std::min<std::uint64_t>(total,65536);
    std::vector<float> samples; samples.reserve(count);
    std::uint64_t next=0,negative=0;float low=0,high=0;
    auto sample_index=[&](std::uint64_t i) { return total==count?i:((i*2+1)*total)/(count*2); };
    for(unsigned y=0;y<height;++y) {
      fetch(y);const auto offset=std::size_t(y-cached)*gstride;
      for(std::size_t i=0;i<gstride;++i) {
        const auto v=grid[offset+i];low=std::min(low,v);high=std::max(high,v);negative+=v<0;
        const auto position=std::uint64_t(y)*gstride+i;
        if(next<count&&position==sample_index(next)) { samples.push_back(v);++next; }
      }
    }
    gain=stream_codebook(*request.gain,request.encoding==OutputEncoding::Adaptive,request.presentation_frame,low,high,samples,negative);
    validate_encoding_headroom(request.encoding,gain->alternate_headroom);
  }
  EncodingRows base_rows{width,height,3,[&](unsigned y,std::span<float> out) {
    fetch(y);std::copy_n(base.data()+std::size_t(y-cached)*stride,stride,out.data());
  }};
  EncodingRows codes{width,height,channels,[&](unsigned y,std::span<float> out) {
    fetch(y);const auto offset=std::size_t(y-cached)*gstride;
    const auto range=gain->gain_max-gain->gain_min;
    for(unsigned x=0;x<width;++x)for(unsigned c=0;c<channels;++c) {
      const auto i=std::size_t(x)*channels+c;
      const auto v=request.encoding==OutputEncoding::Adaptive?std::max(0.f,grid[offset+i]):grid[offset+i];
      const auto normalized=range>kEpsilon?clamp_finite((v-gain->gain_min)/range,0.f,1.f):0.f;
      const auto encoded=encode_gain_code(normalized,gain->gamma);
      const auto code=!request.presentation_frame?quantize_gain_code_dithered(encoded,x,y):
          std::abs(v)<=kFrameZeroTolerance?gain->zero_code:std::round(encoded*255)/255;
      if(request.frame_photo) {
        const auto& f=*request.frame_photo;
        if((x<f.x||x>=f.x+f.width||y<f.y||y>=f.y+f.height)&&code!=gain->zero_code)
          throw std::runtime_error("the framed mat carries gain outside the photograph rectangle");
      }
      out[i]=code;
    }
  }};
  PhotoMetadata photo;
  if(request.exif&&request.exif_size)photo=read_exif(request.exif,request.exif_size).metadata;
  photo.orientation=1;
  StagingFile staged(reserve_staging_beside(request.output));
  switch(request.encoding) {
    case OutputEncoding::SdrJpeg:write_sdr_jpeg_rows(base_rows,photo,request.quality,resolved_gamut(request),staged.path);break;
    case OutputEncoding::SdrTiff:write_sdr_tiff_rows(base_rows,photo,resolved_gamut(request),staged.path);break;
    case OutputEncoding::IsoGainMapJpeg:write_gain_map_jpeg_rows(base_rows,codes,gain->metadata,photo,request.quality,request.presentation_frame,staged.path);break;
    default: {
      const auto bytes=encode_heic_rows(base_rows,codes,gain->metadata,gain->alternate_headroom,photo,request.encoding,request.quality,request.depth,request.hevc_preset);
      write_binary_file_atomic(staged.path,bytes,true);break;
    }
  }
  // Release row planes before the existing (whole-image) verification phase.
  base.clear();base.shrink_to_fit();grid.clear();grid.shrink_to_fit();
  check_cancelled();
  if(request.verify) { const auto bytes=read_binary_file(staged.path);verify_encoded_output(bytes,request.encoding); }
  if(request.frame_photo)verify_framed_mat(request,staged.path);
  const auto size=std::filesystem::file_size(staged.path);
  const auto report=package_report(request,gain,size);
  check_cancelled();
  const int fd=::open(staged.path.c_str(),O_RDONLY|O_CLOEXEC);
  if(fd<0)throw std::runtime_error("cannot open staged package");
  const int synced=::fsync(fd);
  const int closed=::close(fd);
  if(synced || closed)throw std::runtime_error("cannot flush or close staged package");
  if(request.overwrite) {
    if(::rename(staged.path.c_str(),request.output.c_str()))throw std::system_error(errno,std::generic_category(),"cannot publish package");
  } else {
    if(::link(staged.path.c_str(),request.output.c_str()))throw std::system_error(errno,std::generic_category(),"cannot publish package");
  }
  return report;
}

}  // namespace hyperdr

#include "hyperdr/image/color.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "internal/budget.hpp"
#include "internal/raw.hpp"
#include "hyperdr/foundation/version.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

void check_raw(int code, const char* operation) {
  // LibRaw uses negative values for its own enum and positive values for errno.
  // Both LIBRAW_UNSUFFICIENT_MEMORY and the system ENOMEM therefore mean the
  // same thing even though their signs differ.
  if (code == LIBRAW_UNSUFFICIENT_MEMORY || code == ENOMEM) {
    throw RawMemoryError(std::string(operation) +
                         ": insufficient memory for requested-resolution RAW processing");
  }
  if (code != LIBRAW_SUCCESS) {
    throw std::runtime_error(std::string(operation) + ": " +
                             libraw_strerror(code));
  }
}

std::string safe_string(const char* value) { return value ? std::string(value) : std::string{}; }

constexpr std::uint64_t kSystemReserveBytes =
    512ULL * 1024ULL * 1024ULL;

void check_raw_memory_admission(std::uint64_t raw_width,
                                std::uint64_t raw_height,
                                std::uint64_t output_width,
                                std::uint64_t output_height) {
  const auto required = codec::raw_pipeline_bytes(
      raw_width, raw_height, output_width, output_height);
  const auto available = available_memory_bytes();
  if (available != 0 &&
      (available <= kSystemReserveBytes ||
       required > available - kSystemReserveBytes)) {
    const auto mib = [](std::uint64_t bytes) {
      return (bytes + (1ULL << 20U) - 1U) >> 20U;
    };
    throw RawMemoryError(
        "insufficient memory for requested RAW decode " +
        std::to_string(output_width) + "x" + std::to_string(output_height) +
        " (approximately " + std::to_string(mib(required)) +
        " MiB required, " + std::to_string(mib(available)) +
        " MiB currently available)");
  }
}

struct LensShadingMap {
  std::uint32_t width{};
  std::uint32_t height{};
  std::uint32_t channels{};
  std::vector<float> gains;
};

struct LinearizationLut {
  std::vector<float> samples;
  bool normalized{false};
};

struct RawCallbackContext {
  const LensShadingMap* lens_shading{};
  std::vector<std::array<std::uint16_t, 4>>* captured_image{};
  std::uint32_t* captured_width{};
  std::uint32_t* captured_height{};
};

// LibRaw's processing callbacks receive the LibRaw object as their only
// argument. A thread-local context keeps optional calibration state attached
// to that synchronous call without a process-global pointer, so concurrent
// previews on different threads remain independent.
thread_local RawCallbackContext* current_raw_callback_context = nullptr;

class RawCallbackScope {
 public:
  explicit RawCallbackScope(RawCallbackContext& context)
      : previous_(current_raw_callback_context) {
    current_raw_callback_context = &context;
  }
  ~RawCallbackScope() { current_raw_callback_context = previous_; }

  RawCallbackScope(const RawCallbackScope&) = delete;
  RawCallbackScope& operator=(const RawCallbackScope&) = delete;

 private:
  RawCallbackContext* previous_;
};

class CallbackLibRaw : public LibRaw {
 public:
  void set_pre_preinterpolate_callback(process_step_callback callback) {
    callbacks.pre_preinterpolate_cb = callback;
  }
  void set_pre_converttorgb_callback(process_step_callback callback) {
    callbacks.pre_converttorgb_cb = callback;
  }
};

void require_calibration_file(const std::filesystem::path& path,
                              const char* label) {
  if (path.empty()) return;
  std::error_code ec;
  if (!std::filesystem::is_regular_file(path, ec) || ec) {
    throw std::invalid_argument(std::string(label) + " does not exist: " +
                                path_utf8(path));
  }
}

void validate_raw_options(const RawDecodeOptions& options) {
  if (!(std::isfinite(options.digital_gain) && options.digital_gain > 0.0F &&
        options.digital_gain <= 64.0F)) {
    throw std::invalid_argument("RAW digital gain must be finite and in (0,64]");
  }
  require_calibration_file(options.bad_pixel_map, "RAW bad-pixel map");
  require_calibration_file(options.dark_frame, "RAW dark frame");
  require_calibration_file(options.linearization_lut,
                           "RAW linearization LUT");
  require_calibration_file(options.lens_shading_map,
                           "RAW lens-shading map");
}

std::vector<double> read_numeric_text(const std::filesystem::path& path,
                                       const char* label) {
  std::ifstream input(path);
  if (!input) {
    throw std::invalid_argument(std::string("cannot read ") + label + ": " +
                                path_utf8(path));
  }
  std::vector<double> values;
  std::string line;
  while (std::getline(input, line)) {
    if (const auto comment = line.find('#'); comment != std::string::npos) {
      line.resize(comment);
    }
    std::istringstream stream(line);
    std::string token;
    while (stream >> token) {
      std::size_t used = 0;
      double value = 0.0;
      try {
        value = std::stod(token, &used);
      } catch (const std::exception&) {
        throw std::invalid_argument(std::string(label) + " contains a non-number");
      }
      if (used != token.size() || !std::isfinite(value)) {
        throw std::invalid_argument(std::string(label) + " contains a non-finite number");
      }
      values.push_back(value);
    }
  }
  if (values.empty()) {
    throw std::invalid_argument(std::string(label) + " is empty");
  }
  return values;
}

std::size_t checked_count(double value, const char* label) {
  if (!(value >= 1.0 && value <= static_cast<double>(std::numeric_limits<std::uint32_t>::max()) &&
        std::floor(value) == value)) {
    throw std::invalid_argument(std::string(label) + " has an invalid size");
  }
  return static_cast<std::size_t>(value);
}

LinearizationLut read_linearization_lut(const std::filesystem::path& path) {
  if (path.empty()) return {};
  const auto values = read_numeric_text(path, "RAW linearization LUT");
  const auto count = checked_count(values.front(), "RAW linearization LUT length");
  if (count < 2 || values.size() != count + 1) {
    throw std::invalid_argument(
        "RAW linearization LUT must contain N followed by exactly N samples");
  }
  LinearizationLut lut;
  lut.samples.reserve(count);
  lut.normalized = true;
  for (std::size_t i = 0; i < count; ++i) {
    const double value = values[i + 1];
    if (value < 0.0 || value > 1.0) lut.normalized = false;
    if (value < 0.0 || value > 65535.0) {
      throw std::invalid_argument(
          "RAW linearization LUT samples must be in [0,65535]");
    }
    lut.samples.push_back(static_cast<float>(value));
  }
  return lut;
}

LensShadingMap read_lens_shading_map(const std::filesystem::path& path) {
  if (path.empty()) return {};
  const auto values = read_numeric_text(path, "RAW lens-shading map");
  if (values.size() < 4) {
    throw std::invalid_argument(
        "RAW lens-shading map must start with width height channels");
  }
  const auto width = checked_count(values[0], "RAW lens-shading map width");
  const auto height = checked_count(values[1], "RAW lens-shading map height");
  const auto channels = checked_count(values[2], "RAW lens-shading map channels");
  if (width == 0 || height == 0 ||
      (channels != 1 && channels != 3 && channels != 4)) {
    throw std::invalid_argument(
        "RAW lens-shading map channels must be 1, 3, or 4");
  }
  constexpr std::size_t kMaximumMapSamples = 64U * 1024U * 1024U;
  if (width > kMaximumMapSamples / height ||
      width * height > kMaximumMapSamples / channels ||
      values.size() != 3 + width * height * channels) {
    throw std::invalid_argument(
        "RAW lens-shading map has the wrong number of samples");
  }
  LensShadingMap map;
  map.width = static_cast<std::uint32_t>(width);
  map.height = static_cast<std::uint32_t>(height);
  map.channels = static_cast<std::uint32_t>(channels);
  map.gains.reserve(width * height * channels);
  for (std::size_t i = 3; i < values.size(); ++i) {
    const double value = values[i];
    if (!(value > 0.0 && value <= 64.0)) {
      throw std::invalid_argument(
          "RAW lens-shading gains must be finite and in (0,64]");
    }
    map.gains.push_back(static_cast<float>(value));
  }
  return map;
}

float bilinear_gain(const LensShadingMap& map, float x, float y,
                    std::uint32_t channel) {
  if (map.gains.empty()) return 1.0F;
  const float fx = std::clamp(x, 0.0F, 1.0F) * (map.width - 1U);
  const float fy = std::clamp(y, 0.0F, 1.0F) * (map.height - 1U);
  const auto x0 = static_cast<std::uint32_t>(fx);
  const auto y0 = static_cast<std::uint32_t>(fy);
  const auto x1 = std::min(x0 + 1U, map.width - 1U);
  const auto y1 = std::min(y0 + 1U, map.height - 1U);
  const float tx = fx - x0;
  const float ty = fy - y0;
  const auto sample = [&](std::uint32_t sx, std::uint32_t sy) {
    const auto index =
        (static_cast<std::size_t>(sy) * map.width + sx) * map.channels + channel;
    return map.gains[index];
  };
  const float top = sample(x0, y0) * (1.0F - tx) + sample(x1, y0) * tx;
  const float bottom = sample(x0, y1) * (1.0F - tx) + sample(x1, y1) * tx;
  return top * (1.0F - ty) + bottom * ty;
}

std::uint32_t lsc_channel_for_cfa(const LibRaw& raw, std::uint32_t c,
                                  std::uint32_t map_channels) {
  if (map_channels == 1) return 0;
  if (map_channels == 4) return std::min(c, 3U);
  const char role = c < 5 ? raw.imgdata.idata.cdesc[c] : '\0';
  if (role == 'R') return 0;
  if (role == 'B') return 2;
  return 1;
}

void apply_lens_shading_to_mosaic(LibRaw& raw, const LensShadingMap& map) {
  if (!raw.imgdata.image || map.gains.empty()) return;
  const auto width = static_cast<std::uint32_t>(raw.imgdata.sizes.iwidth);
  const auto height = static_cast<std::uint32_t>(raw.imgdata.sizes.iheight);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      auto& pixel = raw.imgdata.image[static_cast<std::size_t>(y) * width + x];
      for (std::uint32_t c = 0; c < 4; ++c) {
        const auto plane = lsc_channel_for_cfa(raw, c, map.channels);
        const float gain = bilinear_gain(
            map, width > 1 ? static_cast<float>(x) / (width - 1U) : 0.0F,
            height > 1 ? static_cast<float>(y) / (height - 1U) : 0.0F,
            plane);
        const auto corrected = static_cast<long>(std::lround(pixel[c] * gain));
        pixel[c] = static_cast<std::uint16_t>(
            std::clamp<long>(corrected, 0L, 65535L));
      }
    }
  }
}

void raw_pre_preinterpolate_callback(void* object) {
  auto* raw = static_cast<LibRaw*>(object);
  if (current_raw_callback_context != nullptr &&
      current_raw_callback_context->lens_shading != nullptr) {
    apply_lens_shading_to_mosaic(
        *raw, *current_raw_callback_context->lens_shading);
  }
}

void raw_capture_before_rgb_callback(void* object) {
  auto* raw = static_cast<LibRaw*>(object);
  auto* context = current_raw_callback_context;
  if (context == nullptr || context->captured_image == nullptr ||
      raw->imgdata.image == nullptr) {
    return;
  }
  const auto width = static_cast<std::uint32_t>(raw->imgdata.sizes.iwidth);
  const auto height = static_cast<std::uint32_t>(raw->imgdata.sizes.iheight);
  const auto count = static_cast<std::size_t>(width) * height;
  context->captured_image->resize(count);
  for (std::size_t i = 0; i < count; ++i) {
    for (std::uint32_t c = 0; c < 4; ++c) {
      (*context->captured_image)[i][c] = raw->imgdata.image[i][c];
    }
  }
  if (context->captured_width != nullptr) *context->captured_width = width;
  if (context->captured_height != nullptr) *context->captured_height = height;
}

float raw_white_level(const LibRaw& raw) {
  const auto maximum = raw.imgdata.color.maximum;
  if (maximum > 0) return static_cast<float>(maximum);
  const auto dng_white = raw.imgdata.rawdata.color.dng_levels.dng_whitelevel[0];
  if (dng_white > 0) return static_cast<float>(dng_white);
  const auto bits = raw.imgdata.rawdata.color.raw_bps;
  if (bits > 0 && bits < 31) return static_cast<float>((1U << bits) - 1U);
  return 65535.0F;
}

void apply_linearization_lut(LibRaw& raw, const LinearizationLut& lut) {
  if (lut.samples.empty()) return;
  const auto& sizes = raw.imgdata.rawdata.sizes;
  const float input_white = std::max(1.0F, raw_white_level(raw));
  const auto map_value = [&](std::uint16_t value) {
    const float position = std::clamp(value / input_white, 0.0F, 1.0F) *
                           static_cast<float>(lut.samples.size() - 1U);
    const auto index = static_cast<std::size_t>(position);
    const auto next = std::min(index + 1U, lut.samples.size() - 1U);
    const float fraction = position - static_cast<float>(index);
    const float mapped_code =
        lut.samples[index] * (1.0F - fraction) + lut.samples[next] * fraction;
    const float mapped = lut.normalized ? mapped_code * input_white : mapped_code;
    return static_cast<std::uint16_t>(std::clamp<long>(
        std::lround(mapped), 0L, 65535L));
  };
  if (raw.imgdata.rawdata.raw_image != nullptr) {
    const auto row_stride = std::max<std::uint32_t>(
        1U, sizes.raw_pitch / static_cast<unsigned>(sizeof(std::uint16_t)));
    for (std::uint32_t y = 0; y < sizes.raw_height; ++y) {
      auto* row = raw.imgdata.rawdata.raw_image +
                  static_cast<std::size_t>(y) * row_stride;
      for (std::uint32_t x = 0; x < sizes.raw_width; ++x) row[x] = map_value(row[x]);
    }
    return;
  }
  if (raw.imgdata.rawdata.color4_image != nullptr) {
    const auto row_stride = std::max<std::uint32_t>(
        1U, sizes.raw_pitch / (4U * static_cast<unsigned>(sizeof(std::uint16_t))));
    for (std::uint32_t y = 0; y < sizes.raw_height; ++y) {
      auto* row = raw.imgdata.rawdata.color4_image +
                  static_cast<std::size_t>(y) * row_stride;
      for (std::uint32_t x = 0; x < sizes.raw_width; ++x)
        for (std::uint32_t c = 0; c < 4; ++c) row[x][c] = map_value(row[x][c]);
    }
    return;
  }
  throw std::runtime_error(
      "RAW linearization LUT requires an unpacked Bayer buffer");
}

void correct_auto_bad_pixels(LibRaw& raw) {
  if (raw.imgdata.rawdata.raw_image == nullptr) {
    throw std::runtime_error(
        "automatic RAW bad-pixel correction requires a Bayer buffer");
  }
  if (raw.imgdata.idata.filters == 0 || raw.imgdata.idata.filters < 1000) {
    throw std::runtime_error(
        "automatic RAW bad-pixel correction supports Bayer RAW only");
  }
  const auto& sizes = raw.imgdata.rawdata.sizes;
  const auto width = static_cast<std::uint32_t>(sizes.width);
  const auto height = static_cast<std::uint32_t>(sizes.height);
  const auto left = static_cast<std::uint32_t>(sizes.left_margin);
  const auto top = static_cast<std::uint32_t>(sizes.top_margin);
  const auto row_stride = std::max<std::uint32_t>(
      1U, sizes.raw_pitch / static_cast<unsigned>(sizeof(std::uint16_t)));
  const float white = std::max(1.0F, raw_white_level(raw));
  float black = static_cast<float>(raw.imgdata.color.black);
  for (const unsigned channel_black : raw.imgdata.color.cblack) {
    black = std::max(black, static_cast<float>(channel_black));
  }
  auto& pixels = raw.imgdata.rawdata.raw_image;
  std::array<std::uint16_t, 4> neighbours{};
  for (std::uint32_t y = 2; y + 2 < height; ++y) {
    for (std::uint32_t x = 2; x + 2 < width; ++x) {
      const auto sensor_y = y + top;
      const auto sensor_x = x + left;
      const auto c = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
      if (c < 0 || c > 3) continue;
      auto& centre = pixels[static_cast<std::size_t>(sensor_y) * row_stride + sensor_x];
      const auto same_colour = [&](std::uint32_t nx, std::uint32_t ny) {
        return raw.COLOR(static_cast<int>(ny), static_cast<int>(nx)) == c;
      };
      const std::array<std::pair<std::uint32_t, std::uint32_t>, 4> positions{{
          {x - 2U, y}, {x + 2U, y}, {x, y - 2U}, {x, y + 2U}}};
      std::size_t count = 0;
      for (const auto [nx, ny] : positions) {
        if (!same_colour(nx, ny)) continue;
        neighbours[count++] = pixels[static_cast<std::size_t>(ny + top) * row_stride +
                                     nx + left];
      }
      if (count < 3) continue;
      std::sort(neighbours.begin(), neighbours.begin() + count);
      const float median = static_cast<float>(neighbours[count / 2]);
      const bool dead = centre <= black + 2.0F && median > black + white * 0.02F;
      const bool hot = centre >= white * 0.995F && median < white * 0.80F;
      if (dead || hot) {
        centre = static_cast<std::uint16_t>(std::lround(median));
      }
    }
  }
}

BayerPattern detect_bayer_pattern(LibRaw& raw, std::uint32_t width,
                                  std::uint32_t height) {
  if (width < 2 || height < 2 || raw.imgdata.idata.filters == 0) {
    return BayerPattern::Unknown;
  }
  const auto role = [&](std::uint32_t x, std::uint32_t y) {
    const auto c = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
    return c >= 0 && c < 5 ? raw.imgdata.idata.cdesc[c] : '\0';
  };
  const std::array<char, 4> top_left{{role(0, 0), role(1, 0), role(0, 1),
                                      role(1, 1)}};
  if (top_left == std::array<char, 4>{{'R', 'G', 'G', 'B'}})
    return BayerPattern::RGGB;
  if (top_left == std::array<char, 4>{{'B', 'G', 'G', 'R'}})
    return BayerPattern::BGGR;
  if (top_left == std::array<char, 4>{{'G', 'R', 'B', 'G'}})
    return BayerPattern::GRBG;
  if (top_left == std::array<char, 4>{{'G', 'B', 'R', 'G'}})
    return BayerPattern::GBRG;
  return BayerPattern::Unknown;
}

}  // namespace

namespace codec {

DecodedImage decode_raw(const std::filesystem::path& path,
                        const RawDecodeOptions& options) {
  validate_raw_options(options);
  const auto linearization_lut =
      read_linearization_lut(options.linearization_lut);
  const auto lens_shading = read_lens_shading_map(options.lens_shading_map);
  const std::string bad_pixel_path = path_utf8(options.bad_pixel_map);
  const std::string dark_frame_path = path_utf8(options.dark_frame);

  CallbackLibRaw raw;
  // Parameters that affect camera WB/matrix selection must be configured before
  // open_file(), when LibRaw copies camera calibration data into the pipeline.
  auto& params = raw.imgdata.params;
  params.use_camera_wb = 1;
  params.use_auto_wb = 0;
  params.use_camera_matrix = 1;
  params.no_auto_bright = 1;
  params.output_bps = 16;
  params.half_size = options.half_size ? 1 : 0;
  // ProPhoto's matrix rows sum to one, so neutral highlights fit in LibRaw's
  // 16-bit output. XYZ (output_color=5) has a 1.0888 Z row sum and therefore
  // clips neutral highlights in only that channel before float conversion.
  params.output_color = 4;
  params.gamm[0] = 1.0;
  params.gamm[1] = 1.0;
  params.use_p1_correction = 1;
  if (!bad_pixel_path.empty()) {
    params.bad_pixels = const_cast<char*>(bad_pixel_path.c_str());
  }
  if (!dark_frame_path.empty()) {
    params.dark_frame = const_cast<char*>(dark_frame_path.c_str());
  }
  switch (options.highlight_recovery) {
    case HighlightRecovery::Clip: params.highlight = 0; break;
    case HighlightRecovery::Unclip: params.highlight = 1; break;
    case HighlightRecovery::Blend: params.highlight = 2; break;
    case HighlightRecovery::Reconstruct: params.highlight = 3; break;
  }
  // Correct channel overflow before demosaic; this is specifically intended to
  // prevent artefacts such as magenta clouds.
  params.adjust_maximum_thr = 0.75F;
  check_raw(raw.open_file(path.c_str()), "LibRaw open");

  // LibRaw's only cheap RAW reduction must be selected before unpack(). It is
  // an explicit preview choice: a full export is a full-resolution contract,
  // so this decoder must never turn a successful 60 MP export into 15 MP merely
  // because an internal working-set estimate was crossed.
  const auto& sizes = raw.imgdata.sizes;
  const std::uint64_t full_width = sizes.width;
  const std::uint64_t full_height = sizes.height;
  const std::uint64_t sensor_width =
      sizes.raw_width ? sizes.raw_width : sizes.width;
  const std::uint64_t sensor_height =
      sizes.raw_height ? sizes.raw_height : sizes.height;
  if (!raw_input_budget_ok(sensor_width, sensor_height) ||
      !raw_input_budget_ok(full_width, full_height)) {
    throw std::runtime_error(
        "RAW sensor raster " + std::to_string(sensor_width) + "x" +
        std::to_string(sensor_height) +
        " exceeds the supported 240869376-pixel input limit");
  }
  const std::uint64_t decode_width =
      params.half_size ? (full_width + 1U) / 2U : full_width;
  const std::uint64_t decode_height =
      params.half_size ? (full_height + 1U) / 2U : full_height;
  check_raw_memory_admission(sensor_width, sensor_height,
                             decode_width, decode_height);
  const bool swaps_axes = (sizes.flip & 4) != 0;
  DecodeInfo decode;
  decode.sensor_width = static_cast<std::uint32_t>(sensor_width);
  decode.sensor_height = static_cast<std::uint32_t>(sensor_height);
  decode.target_width = static_cast<std::uint32_t>(
      swaps_axes ? full_height : full_width);
  decode.target_height = static_cast<std::uint32_t>(
      swaps_axes ? full_width : full_height);
  decode.requested_crop_left = sizes.left_margin;
  decode.requested_crop_top = sizes.top_margin;
  decode.resolution_reduced = params.half_size != 0;
  const auto mark_degraded = [&](std::string_view reason) {
    decode.degraded = true;
    decode.degradation_reasons.emplace_back(reason);
  };
  // With highlight recovery enabled dcraw normalises by the largest WB
  // multiplier instead of the smallest, darkening the whole frame by
  // dmin/dmax. cam_mul is the camera/as-shot WB that scale_colors uses for this
  // normalisation; pre_mul already includes colour-calibration scaling and
  // over-corrects this A7R V by about 0.06 EV. Capture cam_mul before
  // dcraw_process() mutates the colour state and restore the exposure later in
  // float, where HDR values may exceed 1.0 without clipping.
  float exposure_gain = 1.0F;
  if (options.highlight_recovery != HighlightRecovery::Clip) {
    float dmin = std::numeric_limits<float>::max();
    float dmax = 0.0F;
    for (const float multiplier : raw.imgdata.color.cam_mul) {
      if (!(multiplier > 0.0F) || !std::isfinite(multiplier)) continue;
      dmin = std::min(dmin, multiplier);
      dmax = std::max(dmax, multiplier);
    }
    if (dmin > 0.0F && dmax > dmin) exposure_gain = dmax / dmin;
  }

  check_raw(raw.unpack(), "LibRaw unpack");
  apply_linearization_lut(raw, linearization_lut);
  if (options.auto_bad_pixel_correction) correct_auto_bad_pixels(raw);
#if defined(LIBRAW_VERSION) && defined(LIBRAW_MAKE_VERSION)
#if LIBRAW_VERSION >= LIBRAW_MAKE_VERSION(0, 21, 0)
  // raw_inset_crops is expressed in the sensor coordinate system. Promote the
  // camera's DefaultCrop to LibRaw's margins before demosaic so half-size,
  // orientation and CFA alignment are all handled by LibRaw itself.
  const auto& default_crop = raw.imgdata.sizes.raw_inset_crops[0];
  decode.default_crop_present =
      default_crop.cleft != 0xffff && default_crop.ctop != 0xffff &&
      default_crop.cwidth > 0 && default_crop.cheight > 0;
  if (decode.default_crop_present) {
    decode.requested_crop_left = default_crop.cleft;
    decode.requested_crop_top = default_crop.ctop;
    decode.target_width =
        swaps_axes ? default_crop.cheight : default_crop.cwidth;
    decode.target_height =
        swaps_axes ? default_crop.cwidth : default_crop.cheight;
    const std::uint64_t raw_width =
        sizes.raw_width ? sizes.raw_width : sizes.width;
    const std::uint64_t raw_height =
        sizes.raw_height ? sizes.raw_height : sizes.height;
    const std::uint64_t right = static_cast<std::uint64_t>(default_crop.cleft) +
                                static_cast<std::uint64_t>(default_crop.cwidth);
    const std::uint64_t bottom = static_cast<std::uint64_t>(default_crop.ctop) +
                                 static_cast<std::uint64_t>(default_crop.cheight);
    const bool crop_in_bounds =
        static_cast<std::uint64_t>(default_crop.cleft) <= raw_width &&
        static_cast<std::uint64_t>(default_crop.ctop) <= raw_height &&
        right <= raw_width && bottom <= raw_height;
    if (!crop_in_bounds) {
      // Do not pass malformed camera metadata to the dependency. Continue
      // with LibRaw's visible area, but leave target_* as the unmet request so
      // no consumer reads decoded_*/target_* as a scale ratio.
      decode.target_dimensions_applied = false;
      mark_degraded("default_crop_out_of_bounds");
    } else {
      // maxcrop is passed explicitly even though 0.55 is the current LibRaw
      // default: the rejection path is covered by a test, so inheriting the
      // default would let a LibRaw upgrade change both the behaviour and the
      // test's meaning at once, with a failure message pointing elsewhere.
      // Returns adjindex + 1, so 1 -- not merely non-zero -- is crops[0].
      if (raw.adjust_to_raw_inset_crop(1, 0.55F) != 1) {
        // The maxcrop guard rejected the metadata. Continue with LibRaw's
        // visible area, but leave target_* as the unmet request and say so, so
        // no consumer reads decoded_*/target_* as a scale ratio.
        decode.target_dimensions_applied = false;
        mark_degraded("default_crop_rejected");
      }
    }
  }
#endif
#endif
  {
    RawCallbackContext callback_context;
    callback_context.lens_shading = lens_shading.gains.empty() ? nullptr
                                                                 : &lens_shading;
    RawCallbackScope callback_scope(callback_context);
    if (callback_context.lens_shading != nullptr) {
      raw.set_pre_preinterpolate_callback(raw_pre_preinterpolate_callback);
    }
    check_raw(raw.dcraw_process(), "LibRaw demosaic");
  }
  int error = 0;
  std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)>
      processed(raw.dcraw_make_mem_image(&error), &LibRaw::dcraw_clear_mem);
  check_raw(error, "LibRaw memory image");
  if (!processed) {
    throw RawMemoryError(
        "LibRaw memory image: insufficient memory for processed RAW pixels");
  }
  if (processed->type != LIBRAW_IMAGE_BITMAP || processed->colors < 3 ||
      processed->bits != 16)
    throw std::runtime_error("LibRaw did not return a 16-bit RGB bitmap");

  DecodedImage result;
  decode.decoded_width = processed->width;
  decode.decoded_height = processed->height;
  decode.delivered_crop_left = raw.imgdata.sizes.left_margin;
  decode.delivered_crop_top = raw.imgdata.sizes.top_margin;
  result.decode = std::move(decode);
  result.linear_p3 = FloatImage(processed->width, processed->height, 3);
  const auto* pixels = reinterpret_cast<const std::uint16_t*>(processed->data);
  parallel_for_rows(processed->height, [&](const std::uint32_t y) {
    const auto row_start = static_cast<std::size_t>(y) * processed->width;
    for (std::uint32_t x = 0; x < processed->width; ++x) {
      const auto output_index = row_start + x;
      const auto input_index =
          output_index * processed->colors;
      const float r = pixels[input_index] / 65535.0F * exposure_gain *
                      options.digital_gain;
      const float g = pixels[input_index + 1] / 65535.0F * exposure_gain *
                      options.digital_gain;
      const float b = pixels[input_index + 2] / 65535.0F * exposure_gain *
                      options.digital_gain;
      const auto p3 = prophoto_to_linear_p3(r, g, b);
      result.linear_p3.pixels[output_index * 3] = p3[0];
      result.linear_p3.pixels[output_index * 3 + 1] = p3[1];
      result.linear_p3.pixels[output_index * 3 + 2] = p3[2];
    }
  });

  const auto& other = raw.imgdata.other;
  result.metadata.make = safe_string(raw.imgdata.idata.make);
  result.metadata.model = safe_string(raw.imgdata.idata.model);
  result.metadata.lens = safe_string(raw.imgdata.lens.Lens);
  result.metadata.lens_make = safe_string(raw.imgdata.lens.LensMake);
  result.metadata.artist = safe_string(other.artist);
  result.metadata.software = std::string("HyperDR ") + kVersion;
  if (raw.imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0) {
    result.metadata.focal_length_35mm =
        static_cast<double>(raw.imgdata.lens.makernotes.FocalLengthIn35mmFormat);
  }
  const auto capture_value = [](double value) -> std::optional<float> {
    if (!(std::isfinite(value) && value > 0.0 &&
          value <= static_cast<double>(std::numeric_limits<float>::max()))) {
      return std::nullopt;
    }
    return static_cast<float>(value);
  };
  result.capture.iso = capture_value(other.iso_speed);
  result.capture.exposure_time_seconds = capture_value(other.shutter);
  result.capture.aperture_f_number = capture_value(other.aperture);
  if (result.capture.iso) {
    result.metadata.iso = static_cast<std::uint32_t>(std::min<double>(
        *result.capture.iso, std::numeric_limits<std::uint32_t>::max()));
  }
  result.metadata.exposure_seconds = result.capture.exposure_time_seconds.value_or(0.0F);
  result.metadata.aperture = result.capture.aperture_f_number.value_or(0.0F);
  result.metadata.focal_length_mm = other.focal_len;
  if (other.timestamp > 0) {
    std::tm time{};
    localtime_s(&time, &other.timestamp);
    char buffer[32]{};
    if (std::strftime(buffer, sizeof(buffer), "%Y:%m:%d %H:%M:%S", &time)) result.metadata.date_time = buffer;
  }
#if defined(LIBRAW_VERSION) && defined(LIBRAW_MAKE_VERSION)
#if LIBRAW_VERSION >= LIBRAW_MAKE_VERSION(0, 19, 0)
  // Only a fix the camera actually parsed is carried through; a zeroed struct
  // would otherwise be written out as a valid position off the coast of Africa.
  const auto& gps = other.parsed_gps;
  if (gps.gpsparsed != 0) {
    const auto to_degrees = [](const float parts[3]) {
      return static_cast<double>(parts[0]) + static_cast<double>(parts[1]) / 60.0 +
             static_cast<double>(parts[2]) / 3600.0;
    };
    GpsPosition position;
    position.latitude_degrees = to_degrees(gps.latitude);
    position.longitude_degrees = to_degrees(gps.longitude);
    if (gps.latref == 'S' || gps.latref == 's') {
      position.latitude_degrees = -position.latitude_degrees;
    }
    if (gps.longref == 'W' || gps.longref == 'w') {
      position.longitude_degrees = -position.longitude_degrees;
    }
    if (std::isfinite(gps.altitude) && gps.altitude != 0.0F) {
      position.altitude_metres =
          gps.altref != 0 ? -static_cast<double>(gps.altitude)
                          : static_cast<double>(gps.altitude);
    }
    if (std::isfinite(position.latitude_degrees) &&
        std::isfinite(position.longitude_degrees) &&
        std::abs(position.latitude_degrees) <= 90.0 &&
        std::abs(position.longitude_degrees) <= 180.0) {
      result.metadata.gps = position;
    }
  }
#endif
#endif
  // LibRaw applies the sensor orientation while rendering, so the encoded pixels are top-left.
  result.metadata.orientation = 1;
  return result;
}

}  // namespace codec

RawMosaic decode_raw_mosaic(const std::filesystem::path& path,
                            const RawDecodeOptions& options) {
  validate_raw_options(options);
  const auto linearization_lut =
      read_linearization_lut(options.linearization_lut);
  const auto lens_shading = read_lens_shading_map(options.lens_shading_map);
  const std::string bad_pixel_path = path_utf8(options.bad_pixel_map);
  const std::string dark_frame_path = path_utf8(options.dark_frame);

  CallbackLibRaw raw;
  auto& params = raw.imgdata.params;
  params.use_camera_wb = 0;
  params.use_auto_wb = 0;
  params.use_camera_matrix = 0;
  params.no_auto_bright = 1;
  params.output_bps = 16;
  params.output_color = 0;
  params.no_auto_scale = 1;
  params.no_interpolation = 1;
  params.half_size = 0;
  params.use_p1_correction = 1;
  if (!bad_pixel_path.empty()) {
    params.bad_pixels = const_cast<char*>(bad_pixel_path.c_str());
  }
  if (!dark_frame_path.empty()) {
    params.dark_frame = const_cast<char*>(dark_frame_path.c_str());
  }

  check_raw(raw.open_file(path.c_str()), "LibRaw open RAW mosaic");
  const auto& sizes = raw.imgdata.sizes;
  const std::uint64_t width = sizes.width;
  const std::uint64_t height = sizes.height;
  if (!codec::raw_input_budget_ok(width, height)) {
    throw std::runtime_error(
        "RAW image " + std::to_string(width) + "x" + std::to_string(height) +
        " exceeds the supported 240869376-pixel input limit");
  }
  check_raw_memory_admission(width, height, width, height);
  check_raw(raw.unpack(), "LibRaw unpack RAW mosaic");
  apply_linearization_lut(raw, linearization_lut);
  if (options.auto_bad_pixel_correction) correct_auto_bad_pixels(raw);

  std::vector<std::array<std::uint16_t, 4>> captured;
  std::uint32_t captured_width = 0;
  std::uint32_t captured_height = 0;
  RawCallbackContext callback_context;
  callback_context.lens_shading = lens_shading.gains.empty() ? nullptr
                                                               : &lens_shading;
  callback_context.captured_image = &captured;
  callback_context.captured_width = &captured_width;
  callback_context.captured_height = &captured_height;
  {
    RawCallbackScope callback_scope(callback_context);
    raw.set_pre_converttorgb_callback(raw_capture_before_rgb_callback);
    if (callback_context.lens_shading != nullptr) {
      raw.set_pre_preinterpolate_callback(raw_pre_preinterpolate_callback);
    }
    check_raw(raw.dcraw_process(), "LibRaw RAW mosaic processing");
  }
  if (captured.empty() || captured_width == 0 || captured_height == 0) {
    throw std::runtime_error(
        "LibRaw did not expose a Bayer mosaic before RGB conversion");
  }
  if (captured_width != static_cast<std::uint32_t>(raw.imgdata.sizes.iwidth) ||
      captured_height != static_cast<std::uint32_t>(raw.imgdata.sizes.iheight)) {
    throw std::runtime_error("LibRaw RAW mosaic dimensions changed during processing");
  }

  const auto pattern = detect_bayer_pattern(raw, captured_width, captured_height);
  if (pattern == BayerPattern::Unknown) {
    throw std::runtime_error(
        "RAW mosaic is not a supported 2x2 Bayer CFA (X-Trans is not packable)");
  }
  const float white = std::max(1.0F, raw_white_level(raw));
  std::uint32_t bit_depth = raw.imgdata.rawdata.color.raw_bps;
  if (bit_depth == 0 || bit_depth > 32) {
    bit_depth = 1;
    while (bit_depth < 31 && ((1ULL << bit_depth) - 1ULL) < white) ++bit_depth;
  }

  RawMosaic result;
  result.samples = FloatImage(captured_width, captured_height, 1);
  result.pattern = pattern;
  result.white_level.fill(white);
  result.black_level.fill(0.0F);
  result.bit_depth = bit_depth;
  result.black_level_corrected = true;
  for (std::uint32_t y = 0; y < captured_height; ++y) {
    for (std::uint32_t x = 0; x < captured_width; ++x) {
      const auto c = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
      if (c < 0 || c > 3) {
        throw std::runtime_error("LibRaw returned an invalid Bayer channel");
      }
      const auto index = static_cast<std::size_t>(y) * captured_width + x;
      result.samples.at(x, y, 0) =
          static_cast<float>(captured[index][c]) / white * options.digital_gain;
    }
  }
  return result;
}

}  // namespace hyperdr

#include "hyperdr/image/color.hpp"
#include "hyperdr/image/dng_color.hpp"
#include "hyperdr/codec/dcp_profile.hpp"
#include "hyperdr/codec/lens_profile.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "internal/budget.hpp"
#include "internal/dng_opcodes.hpp"
#include "internal/metadata.hpp"
#include "internal/raw.hpp"
#include "internal/raw_highlights.hpp"
#include "internal/raw_geometry.hpp"
#include "internal/raw_sensor_geometry.hpp"
#include "hyperdr/foundation/version.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cctype>
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

struct RawCalibration {
  codec::RawSensorGeometry sensor;
  float white{};
  std::array<unsigned, 4> black{};
  std::uint32_t black_rows{}, black_columns{};
  std::vector<unsigned> black_pattern;
  std::vector<std::uint16_t> dark;
  const LinearizationLut* lut{};
  // A DNG's OpcodeList2 gain maps, in the coordinates of the area above.
  std::vector<codec::DngGainMap> gain_maps;
};

struct RawCallbackContext {
  const LensShadingMap* lens_shading{};
  const RawCalibration* calibration{};
  float lens_shading_scale{1.0F};
  float exposure_gain{1.0F};
  // The white-balance multipliers LibRaw applied, in its channel order.
  std::array<float, 4> applied_multipliers{};
  bool blend_highlights{};
  bool reconstruct_highlights{};
  FloatImage camera;
  codec::RawOutputGeometry geometry;
  unsigned shading_channels{}, shading_step{1}, cfa_period{};
  std::array<unsigned, 4> shading_planes{};
  // Preserve CFA phase before pre_interpolate merges green indices or clears
  // filters for half-size output. LibRaw uses a 6x6 X-Trans or up to 16x16 CFA.
  std::array<std::uint8_t, 256> shading_cfa{};
  std::vector<std::uint16_t>* captured_mosaic{};
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
  CallbackLibRaw() { set_exifparser_handler(read_calibration_signature, this); }

  bool camera_calibration_matches_signature(const std::string& signature) const {
    return camera_calibration_signature_ == signature;
  }

  bool camera_calibration_matches_profile() const {
    return camera_calibration_signature_ == profile_calibration_signature_;
  }

  void set_pre_preinterpolate_callback(process_step_callback callback) {
    callbacks.pre_preinterpolate_cb = callback;
  }
  void set_pre_converttorgb_callback(process_step_callback callback) {
    callbacks.pre_converttorgb_cb = callback;
  }
  void set_post_interpolate_callback(process_step_callback callback) {
    callbacks.post_interpolate_cb = callback;
  }
  void apply_default_median_filter() {
    if (!imgdata.idata.is_foveon && imgdata.idata.colors == 3 && imgdata.params.med_passes > 0)
      median_filter();
  }
  void normalized_black_levels(RawCalibration& calibration) {
    const auto saved_black = imgdata.color.black;
    std::array<unsigned, LIBRAW_CBLACK_SIZE> saved{};
    std::copy(std::begin(imgdata.color.cblack), std::end(imgdata.color.cblack), saved.begin());
    adjust_bl();
    std::copy_n(imgdata.color.cblack, 4, calibration.black.begin());
    calibration.black_rows = imgdata.color.cblack[4];
    calibration.black_columns = imgdata.color.cblack[5];
    const auto count = calibration.black_rows * calibration.black_columns;
    calibration.black_pattern.assign(imgdata.color.cblack + 6,
                                    imgdata.color.cblack + 6 + count);
    imgdata.color.black = saved_black;
    std::copy(saved.begin(), saved.end(), std::begin(imgdata.color.cblack));
  }
  unsigned sample_step() const {
    return 1U << libraw_internal_data.internal_output_params.shrink;
  }
  codec::RawSensorGeometry sensor_geometry() const {
    const auto& s = imgdata.sizes;
    return codec::raw_sensor_geometry(s.width, s.height, s.raw_width, s.raw_height,
        s.left_margin, s.top_margin, libraw_internal_data.internal_output_params.fuji_width,
        libraw_internal_data.unpacker_data.fuji_layout != 0);
  }
  int working_color(int row, int col) {
    // COLOR() expects storage coordinates on Fuji; raw2image uses FC() for
    // its already rearranged working raster.
    return libraw_internal_data.internal_output_params.fuji_width ? FC(row, col) : COLOR(row, col);
  }
  // Where the camera matrix in rgb_cam came from. Read after unpack(), which
  // can still drop the matrix for some formats, and before dcraw_process():
  // with output_color = 0, convert_to_rgb() marks every image as raw colour.
  const char* color_matrix_source() const {
    if (libraw_internal_data.internal_output_params.raw_color) return "none";
    // identify() copies the file's own matrix (DNG ColorMatrix, maker-note
    // matrix) into rgb_cam when use_camera_matrix admits it; otherwise the
    // matrix is LibRaw's per-model table or a format constant.
    const auto& color = imgdata.color;
    return color.cmatrix[0][0] != 0.0F &&
                   std::memcmp(color.rgb_cam, color.cmatrix, sizeof(color.rgb_cam)) == 0
               ? "embedded"
               : "libraw";
  }

 private:
  // LibRaw exposes the calibration matrices but not their signatures. Its
  // TIFF callback is already positioned at a tag's value and restores the
  // stream afterwards. Only IFD0 describes the primary embedded profile.
  static void read_calibration_signature(void* context, int tag, int type, int len,
                                         unsigned int, void* input, INT64) {
    if ((tag >> 20) != 1 || (type != 1 && type != 2) || len <= 0) return;
    const int id = tag & 0xffff;
    if (id != 50931 && id != 50932) return;
    auto& raw = *static_cast<CallbackLibRaw*>(context);
    auto& signature = id == 50931 ? raw.camera_calibration_signature_
                                  : raw.profile_calibration_signature_;
    std::string value(static_cast<std::size_t>(len), '\0');
    auto* stream = static_cast<LibRaw_abstract_datastream*>(input);
    const auto position = stream->tell();
    const auto count = stream->read(value.data(), 1, value.size());
    stream->seek(position, SEEK_SET);
    if (count != len) return;
    if (const auto end = value.find('\0'); end != std::string::npos) value.resize(end);
    signature = std::move(value);
  }

  std::string camera_calibration_signature_;
  std::string profile_calibration_signature_;
};

// A DNG's own colour model, where LibRaw would apply only the D65 ColorMatrix
// whatever the light: both calibrations interpolated at the white LibRaw
// actually balanced to (the reciprocal of the multipliers it applied), with
// CameraCalibration, AnalogBalance and ForwardMatrix. Empty for other files,
// for sensors with other than three colours, for raw data the camera had
// already white balanced, and for a profile the DNG SDK would refuse, all of
// which keep LibRaw's matrix. LibRaw 0.22 leaves parsedfields zero on the
// fields it exposes, so an all-zero matrix is taken as an absent one.
std::optional<Matrix3d> dng_camera_matrix(const CallbackLibRaw& raw,
                                          const std::array<float, 4>& multipliers) {
  const auto& color = raw.imgdata.color;
  if (raw.imgdata.idata.dng_version == 0 || raw.imgdata.idata.colors != 3 ||
      color.as_shot_wb_applied) {
    return std::nullopt;
  }
  const auto read = [](const auto& source) -> std::optional<Matrix3d> {
    Matrix3d matrix{};
    bool any = false;
    for (std::size_t i = 0; i < 3; ++i) {
      for (std::size_t j = 0; j < 3; ++j) {
        const double value = source[i][j];
        if (!std::isfinite(value)) return std::nullopt;
        matrix[i][j] = value;
        any = any || value != 0.0;
      }
    }
    return any ? std::optional<Matrix3d>(matrix) : std::nullopt;
  };
  DngColorProfile profile;
  for (std::size_t k = 0; k < profile.calibrations.size(); ++k) {
    const auto& source = color.dng_color[k];
    auto& calibration = profile.calibrations[k];
    calibration.illuminant = source.illuminant;
    calibration.color_matrix = read(source.colormatrix);
    calibration.forward_matrix = read(source.forwardmatrix);
    // DNG defaults both signatures to empty, so older files still apply
    // calibration. A different profile's signature requires identity instead.
    if (raw.camera_calibration_matches_profile()) {
      calibration.camera_calibration = read(source.calibration);
    }
  }
  std::array<double, 3> neutral{};
  for (std::size_t c = 0; c < 3; ++c) {
    const float gain = color.dng_levels.analogbalance[c];
    profile.analog_balance[c] = std::isfinite(gain) && gain > 0.0F ? gain : 1.0;
    if (!(std::isfinite(multipliers[c]) && multipliers[c] > 0.0F)) return std::nullopt;
    neutral[c] = 1.0 / multipliers[c];
  }
  return dng_camera_to_linear_p3(profile, neutral);
}

// LibRaw's camera RGB -- after white balance, demosaic and highlight handling --
// to RGB on the AP1 primaries at D65, as the columns of a 3x4 matrix: column c
// is the AP1 colour of camera channel c. A DNG's own colour model, when it has
// given one, maps to linear P3; otherwise rgb_cam maps camera RGB to linear
// sRGB (D65), which goes on through P3. A camera without a matrix keeps what
// LibRaw's ProPhoto output gave it: camera RGB read as ProPhoto, with a fourth
// channel dropped.
std::array<std::array<float, 3>, 4> camera_to_ap1_columns(
    const LibRaw& raw, bool has_matrix, const std::optional<Matrix3d>& dng_matrix) {
  std::array<std::array<float, 3>, 4> columns{};
  for (unsigned c = 0; c < columns.size(); ++c) {
    std::array<float, 3> p3{};
    if (dng_matrix) {
      if (c < 3) {
        for (std::size_t i = 0; i < 3; ++i) p3[i] = static_cast<float>((*dng_matrix)[i][c]);
      }
    } else if (has_matrix) {
      const auto& m = raw.imgdata.color.rgb_cam;
      p3 = rec709_to_linear_p3_unclamped(m[0][c], m[1][c], m[2][c]);
    } else if (c < 3) {
      std::array<float, 3> prophoto{};
      prophoto[c] = 1.0F;
      p3 = prophoto_to_linear_p3(prophoto[0], prophoto[1], prophoto[2]);
    }
    columns[c] = linear_p3_to_ap1_d65(p3[0], p3[1], p3[2]);
  }
  return columns;
}

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
  require_calibration_file(options.profile, "RAW DCP profile");
  require_calibration_file(options.lens_profile, "RAW lens profile");
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
    if (!lut.samples.empty() && value < lut.samples.back()) {
      throw std::invalid_argument("RAW linearization LUT must be nondecreasing");
    }
    lut.samples.push_back(static_cast<float>(value));
  }
  if (lut.samples.front() == lut.samples.back())
    throw std::invalid_argument("RAW linearization LUT must retain a signal range");
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

// Supporting vertices bound every bilinear sample in the effective crop.
// Use the same range for both constant-gain detection and integer headroom;
// unused vertices must not reduce the precision of a nonconstant crop.
std::pair<float, float> lens_shading_gain_range(const LensShadingMap& map,
                                               const RawCalibration& calibration,
                                               LibRaw& raw) {
  if (raw.is_fuji_rotated()) {
    // The diamond raster covers the original storage rectangle; its blank
    // corners are not a rectangular crop in calibration coordinates.
    const auto [low, high] = std::minmax_element(map.gains.begin(), map.gains.end());
    return {*low, *high};
  }
  const auto& sizes = raw.imgdata.sizes;
  const auto bounds = [](unsigned offset, unsigned length, unsigned extent,
                         unsigned points) {
    // Match bilinear_gain's float coordinates so a rounded boundary cannot
    // sample a neighbour omitted by an idealized double-precision bound.
    const auto coordinate = [&](unsigned site) {
      const float position = extent > 1 ? static_cast<float>(site) / (extent - 1) : 0;
      return std::clamp(position, 0.0F, 1.0F) * (points - 1);
    };
    return std::pair<unsigned, unsigned>{
        static_cast<unsigned>(std::floor(coordinate(offset))),
        static_cast<unsigned>(std::ceil(coordinate(offset + length - 1)))};
  };
  const auto [x0, x1] = bounds(sizes.left_margin - calibration.sensor.left,
                              sizes.width, calibration.sensor.width, map.width);
  const auto [y0, y1] = bounds(sizes.top_margin - calibration.sensor.top,
                              sizes.height, calibration.sensor.height, map.height);
  float low = map.gains[(static_cast<std::size_t>(y0) * map.width + x0) * map.channels];
  float high = low;
  for (unsigned y = y0; y <= y1; ++y)
    for (unsigned x = x0; x <= x1; ++x)
      for (unsigned c = 0; c < map.channels; ++c) {
        const float gain = map.gains[(static_cast<std::size_t>(y) * map.width + x) * map.channels + c];
        low = std::min(low, gain);
        high = std::max(high, gain);
      }
  return {low, high};
}

// Coordinates remain relative to the original visible sensor area, even when
// LibRaw has cropped the image or packed four sites into one half-size pixel.
std::pair<int, int> calibration_working_site(const LibRaw& raw,
                                            const RawCalibration& calibration,
                                            unsigned x, unsigned y) {
  const auto [sx, sy] = codec::raw_sensor_site(calibration.sensor,
                                              static_cast<int>(x), static_cast<int>(y));
  return {static_cast<int>(raw.imgdata.sizes.left_margin) - static_cast<int>(calibration.sensor.left) + sx,
          static_cast<int>(raw.imgdata.sizes.top_margin) - static_cast<int>(calibration.sensor.top) + sy};
}

std::pair<int, int> calibration_site(CallbackLibRaw& raw,
                                               const RawCalibration& calibration,
                                               unsigned x, unsigned y, unsigned c) {
  const auto step = raw.sample_step();
  unsigned dx = 0, dy = 0;
  if (step == 2) {
    for (unsigned sy = 0; sy < 2; ++sy)
      for (unsigned sx = 0; sx < 2; ++sx)
        if (raw.working_color(y * 2 + sy, x * 2 + sx) == static_cast<int>(c)) {
          dx = sx;
          dy = sy;
        }
  }
  return calibration_working_site(raw, calibration, x * step + dx, y * step + dy);
}

void apply_lens_shading_to_mosaic(CallbackLibRaw& raw, const LensShadingMap& map,
                                 const RawCalibration& calibration, float scale) {
  if (!raw.imgdata.image || map.gains.empty()) return;
  const auto width = static_cast<std::uint32_t>(raw.imgdata.sizes.iwidth);
  const auto height = static_cast<std::uint32_t>(raw.imgdata.sizes.iheight);
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      auto& pixel = raw.imgdata.image[static_cast<std::size_t>(y) * width + x];
      for (std::uint32_t c = 0; c < 4; ++c) {
        if (pixel[c] == 0) continue;
        const auto [sx, sy] = calibration_site(raw, calibration, x, y, c);
        const auto plane = lsc_channel_for_cfa(raw, c, map.channels);
        const float gain = bilinear_gain(
            map, calibration.sensor.width > 1 ? static_cast<float>(sx) / (calibration.sensor.width - 1U) : 0.0F,
            calibration.sensor.height > 1 ? static_cast<float>(sy) / (calibration.sensor.height - 1U) : 0.0F,
            plane);
        // Never amplify an integer sample here. Restore the common scale in
        // float after LibRaw, preserving the headroom requested by the map.
        const auto corrected = static_cast<long>(std::lround(pixel[c] * (gain / scale)));
        pixel[c] = static_cast<std::uint16_t>(
            std::clamp<long>(corrected, 0L, 65535L));
      }
    }
  });
}

void raw_pre_preinterpolate_callback(void* object) {
  auto* raw = static_cast<CallbackLibRaw*>(object);
  auto* context = current_raw_callback_context;
  if (!context) return;
  // scale_colors() has run: pre_mul holds the multipliers it applied, divided
  // by their largest (or, without highlight recovery, their smallest).
  std::copy(std::begin(raw->imgdata.color.pre_mul), std::end(raw->imgdata.color.pre_mul),
            context->applied_multipliers.begin());
  if (!raw->imgdata.params.no_auto_scale && raw->imgdata.params.highlight != 0) {
    const auto& multipliers = raw->imgdata.color.pre_mul;
    const float low = *std::min_element(std::begin(multipliers), std::end(multipliers));
    const float high = *std::max_element(std::begin(multipliers), std::end(multipliers));
    if (std::isfinite(low) && std::isfinite(high) && low > 0.0F)
      context->exposure_gain = high / low;
  }
  if (context->lens_shading != nullptr) {
    if (context->blend_highlights || context->reconstruct_highlights) {
      context->shading_channels = raw->imgdata.idata.colors;
      if (raw->imgdata.idata.filters && raw->imgdata.idata.filters != 9 &&
          context->shading_channels == 3)
        context->shading_channels = 4;
      context->shading_step = raw->sample_step();
      context->cfa_period = raw->imgdata.idata.filters == 9 ? 6 : 16;
      for (unsigned c = 0; c < context->shading_channels; ++c)
        context->shading_planes[c] = lsc_channel_for_cfa(*raw, c, context->lens_shading->channels);
      if (context->shading_step == 2)
        for (unsigned y = 0; y < context->cfa_period; ++y)
          for (unsigned x = 0; x < context->cfa_period; ++x)
            context->shading_cfa[y * context->cfa_period + x] =
                static_cast<std::uint8_t>(raw->working_color(y, x));
    }
    apply_lens_shading_to_mosaic(
        *raw, *context->lens_shading, *context->calibration, context->lens_shading_scale);
  }
}

void raw_capture_before_rgb_callback(void* object) {
  auto* raw = static_cast<LibRaw*>(object);
  auto* context = current_raw_callback_context;
  if (context == nullptr || context->captured_mosaic == nullptr ||
      raw->imgdata.image == nullptr) {
    return;
  }
  const auto width = static_cast<std::uint32_t>(raw->imgdata.sizes.iwidth);
  const auto height = static_cast<std::uint32_t>(raw->imgdata.sizes.iheight);
  const auto count = static_cast<std::size_t>(width) * height;
  context->captured_mosaic->resize(count);
  for (std::size_t i = 0; i < count; ++i) {
    const auto y = static_cast<int>(i / width);
    const auto x = static_cast<int>(i % width);
    const auto c = raw->COLOR(y, x);
    // A non-Bayer layout is rejected after the callback. Keep the C callback
    // non-throwing while copying only the one sensor sample each site owns,
    // instead of four mostly-empty uint16 planes per pixel.
    (*context->captured_mosaic)[i] =
        c >= 0 && c <= 3 ? raw->imgdata.image[i][c] : 0;
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

float linearized_code(float value, const RawCalibration& calibration) {
  const auto& lut = *calibration.lut;
  if (lut.samples.empty()) return value;
  const float position = std::clamp(value / calibration.white, 0.0F, 1.0F) *
                         static_cast<float>(lut.samples.size() - 1U);
  const auto index = static_cast<std::size_t>(position);
  const auto next = std::min(index + 1U, lut.samples.size() - 1U);
  const float mapped = std::lerp(lut.samples[index], lut.samples[next],
                                 position - static_cast<float>(index));
  return lut.normalized ? mapped * calibration.white : mapped;
}

std::vector<std::uint16_t> read_dark_frame(const std::filesystem::path& path,
                                          unsigned width, unsigned height) {
  if (path.empty()) return {};
  std::ifstream input(path, std::ios::binary);
  const auto token = [&]() {
    std::string value;
    while (input >> std::ws && input.peek() == '#') {
      std::getline(input, value);
    }
    input >> value;
    return value;
  };
  if (token() != "P5" || token() != std::to_string(width) ||
      token() != std::to_string(height) || token() != "65535") {
    throw std::invalid_argument(
        "RAW dark frame must be a 16-bit P5 PGM matching the original visible area " +
        std::to_string(width) + "x" + std::to_string(height));
  }
  const int separator = input.get();
  if (separator == '\r' && input.peek() == '\n') input.get();
  if (separator == EOF || !std::isspace(static_cast<unsigned char>(separator)))
    throw std::invalid_argument("RAW dark frame has an invalid PGM header");
  std::vector<std::uint16_t> dark(static_cast<std::size_t>(width) * height);
  input.read(reinterpret_cast<char*>(dark.data()),
             static_cast<std::streamsize>(dark.size() * sizeof(std::uint16_t)));
  if (!input) throw std::invalid_argument("RAW dark frame pixel data is truncated");
  // PGM samples are big endian; supported Windows targets are little endian.
  for (auto& value : dark) value = static_cast<std::uint16_t>((value >> 8) | (value << 8));
  return dark;
}

RawCalibration prepare_calibration(CallbackLibRaw& raw, const LinearizationLut& lut,
                                    const RawDecodeOptions& options,
                                    std::vector<codec::DngGainMap> gain_maps) {
  RawCalibration calibration;
  calibration.sensor = raw.sensor_geometry();
  calibration.white = std::max(1.0F, raw_white_level(raw));
  calibration.lut = &lut;
  raw.normalized_black_levels(calibration);
  calibration.dark = read_dark_frame(options.dark_frame, calibration.sensor.width, calibration.sensor.height);
  calibration.gain_maps = std::move(gain_maps);
  return calibration;
}

// A DNG's three opcode lists, parsed; empty for any other file.
std::array<codec::DngOpcodeList, 3> read_dng_opcodes(const LibRaw& raw) {
  std::array<codec::DngOpcodeList, 3> lists;
  if (raw.imgdata.idata.dng_version == 0) return lists;
  for (std::size_t k = 0; k < lists.size(); ++k) {
    const auto& stored = raw.imgdata.color.dng_levels.rawopcodes[k];
    lists[k] = codec::parse_dng_opcode_list(static_cast<const std::uint8_t*>(stored.data), stored.len,
                                            static_cast<int>(k + 1));
  }
  return lists;
}

// OpcodeList1's bad-pixel fixes, on the stored values of the whole sensor
// image, before anything else touches them. False when one could not be
// applied: the file is not a Bayer mosaic, or the list is implausibly large.
bool apply_dng_bad_pixels(LibRaw& raw, const codec::DngOpcodeList& list) {
  if (list.bad_pixels.empty()) return true;
  auto& data = raw.imgdata.rawdata;
  if (!data.raw_image || raw.imgdata.idata.filters < 1000) return false;
  const std::size_t stride = std::max<std::size_t>(1U, data.sizes.raw_pitch / sizeof(std::uint16_t));
  bool applied = true;
  for (const auto& fix : list.bad_pixels) {
    applied = codec::fix_dng_bad_pixels(data.raw_image, data.sizes.raw_width, data.sizes.raw_height,
                                        stride, fix) &&
              applied;
  }
  return applied;
}

void apply_code_calibration(CallbackLibRaw& raw, const RawCalibration& calibration) {
  if (calibration.lut->samples.empty() && calibration.dark.empty() &&
      calibration.gain_maps.empty()) {
    return;
  }
  auto& data = raw.imgdata.rawdata;
  if (!data.raw_image && !data.color4_image)
    throw std::invalid_argument("RAW code calibration requires an unpacked 16-bit sensor buffer");
  if (!calibration.dark.empty() && (!data.raw_image || !raw.imgdata.idata.filters))
    throw std::invalid_argument("RAW dark-frame calibration requires a CFA sensor buffer");
  const float mapped_white = linearized_code(calibration.white, calibration);
  // A gain map's grid position depends on the row and the column separately,
  // so both are found once per map rather than once per sample.
  struct GainAxes {
    std::vector<codec::DngGainAxis> rows, columns;
  };
  std::vector<GainAxes> axes(calibration.gain_maps.size());
  for (std::size_t i = 0; i < axes.size(); ++i) {
    const auto& map = calibration.gain_maps[i];
    axes[i].rows.resize(calibration.sensor.height);
    axes[i].columns.resize(calibration.sensor.width);
    for (unsigned y = 0; y < calibration.sensor.height; ++y)
      axes[i].rows[y] = codec::dng_gain_axis(y, calibration.sensor.height, map.origin_v, map.spacing_v, map.points_v);
    for (unsigned x = 0; x < calibration.sensor.width; ++x)
      axes[i].columns[x] = codec::dng_gain_axis(x, calibration.sensor.width, map.origin_h, map.spacing_h, map.points_h);
  }
  const auto corrected = [&](std::uint16_t value, unsigned x, unsigned y, unsigned c, unsigned plane) {
    float black = static_cast<float>(calibration.black[c]);
    if (!calibration.black_pattern.empty()) {
      black += calibration.black_pattern[(y % calibration.black_rows) *
                   calibration.black_columns + x % calibration.black_columns];
    }
    const float mapped_black = linearized_code(black, calibration);
    const float range = mapped_white - mapped_black;
    if (!(range > 0.0F))
      throw std::invalid_argument("RAW linearization LUT leaves no range above the black level");
    const float baseline = calibration.dark.empty() ? mapped_black :
        linearized_code(calibration.dark[static_cast<std::size_t>(y) * calibration.sensor.width + x],
                        calibration);
    float signal =
        std::clamp((linearized_code(value, calibration) - baseline) / range, 0.0F, 1.0F);
    // OpcodeList2 acts on these linear values. Each gain map is clipped at
    // white as the DNG SDK clips it, so a corner the map brightens saturates
    // where the centre does and highlight recovery sees one clip level.
    for (std::size_t i = 0; i < calibration.gain_maps.size(); ++i) {
      const auto& map = calibration.gain_maps[i];
      if (!codec::dng_gain_map_covers(map, y, x, plane)) continue;
      signal = std::min(signal * codec::dng_gain(map, axes[i].rows[y], axes[i].columns[x], plane), 1.0F);
    }
    return static_cast<std::uint16_t>(std::lround(std::clamp(signal, 0.0F, 1.0F) * 65535.0F));
  };
  for (unsigned y = 0; y < calibration.sensor.height; ++y) {
    for (unsigned x = 0; x < calibration.sensor.width; ++x) {
      const auto row_bytes = static_cast<std::size_t>(y + calibration.sensor.top) * data.sizes.raw_pitch;
      if (data.raw_image) {
        auto& value = data.raw_image[row_bytes / 2 + x + calibration.sensor.left];
        value = corrected(value, x, y, raw.COLOR(y, x), 0);
      } else {
        auto& value = data.color4_image[row_bytes / 8 + x + calibration.sensor.left];
        for (unsigned c = 0; c < 4; ++c) value[c] = corrected(value[c], x, y, c, c);
      }
    }
  }
  // raw2image_start() restores rawdata.color. Update both copies so LibRaw
  // neither subtracts the old black again nor scales by the old white level.
  for (auto* color : {&raw.imgdata.color, &data.color}) {
    color->black = 0;
    std::fill(std::begin(color->cblack), std::end(color->cblack), 0U);
    color->maximum = 65535;
    color->data_maximum = 0;
  }
  raw.imgdata.params.adjust_maximum_thr = 0.0F;
}

void apply_bad_pixel_map(CallbackLibRaw& raw, const std::filesystem::path& path) {
  if (path.empty()) return;
  auto& data = raw.imgdata.rawdata;
  if (!data.raw_image || !raw.imgdata.idata.filters)
    throw std::invalid_argument("RAW bad-pixel map requires a CFA sensor buffer");
  std::ifstream input(path);
  if (!input) throw std::invalid_argument("cannot read RAW bad-pixel map");
  const auto& sizes = data.sizes;
  const auto sensor = raw.sensor_geometry();
  const auto sample = [&](unsigned x, unsigned y) -> std::uint16_t& {
    return data.raw_image[static_cast<std::size_t>(y + sizes.top_margin) *
                          (sizes.raw_pitch / 2) + x + sizes.left_margin];
  };
  std::string line;
  while (std::getline(input, line)) {
    if (const auto hash = line.find('#'); hash != std::string::npos) line.resize(hash);
    std::istringstream row(line);
    row >> std::ws;
    if (row.eof()) continue;
    int x, y;
    long long timestamp;
    if (!(row >> x >> y >> timestamp))
      throw std::invalid_argument("RAW bad-pixel map requires x y timestamp rows");
    if (x < 0 || y < 0 || static_cast<unsigned>(x) >= sensor.width || static_cast<unsigned>(y) >= sensor.height ||
        timestamp > raw.imgdata.other.timestamp) continue;
    const auto c = raw.COLOR(y, x);
    unsigned sum = 0, count = 0;
    for (int radius = 1; radius <= 2 && count == 0; ++radius) {
      for (int sy = y - radius; sy <= y + radius; ++sy)
        for (int sx = x - radius; sx <= x + radius; ++sx)
          if (sx >= 0 && sy >= 0 && static_cast<unsigned>(sx) < sensor.width && static_cast<unsigned>(sy) < sensor.height &&
              (sx != x || sy != y) && raw.COLOR(sy, sx) == c) {
            sum += sample(sx, sy);
            ++count;
          }
    }
    if (count) sample(x, y) = static_cast<std::uint16_t>(sum / count);
  }
}

void correct_auto_bad_pixels(CallbackLibRaw& raw) {
  if (raw.imgdata.rawdata.raw_image == nullptr) {
    throw std::runtime_error(
        "automatic RAW bad-pixel correction requires a Bayer buffer");
  }
  if (raw.imgdata.idata.filters == 0 || raw.imgdata.idata.filters < 1000) {
    throw std::runtime_error(
        "automatic RAW bad-pixel correction supports Bayer RAW only");
  }
  const auto& sizes = raw.imgdata.rawdata.sizes;
  const auto sensor = raw.sensor_geometry();
  const auto width = sensor.width;
  const auto height = sensor.height;
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
  // In a Fuji storage rectangle one axis is packed twice as densely. A
  // two-site displacement there changes red to blue (or the green plane);
  // four sites are needed to reach the same CFA phase.
  const unsigned dx = sensor.fuji_width && !sensor.fuji_layout ? 4 : 2;
  const unsigned dy = sensor.fuji_width && sensor.fuji_layout ? 4 : 2;
  for (std::uint32_t y = dy; y + dy < height; ++y) {
    for (std::uint32_t x = dx; x + dx < width; ++x) {
      const auto sensor_y = y + top;
      const auto sensor_x = x + left;
      const auto c = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
      if (c < 0 || c > 3) continue;
      auto& centre = pixels[static_cast<std::size_t>(sensor_y) * row_stride + sensor_x];
      const auto same_colour = [&](std::uint32_t nx, std::uint32_t ny) {
        return raw.COLOR(static_cast<int>(ny), static_cast<int>(nx)) == c;
      };
      const std::array<std::pair<std::uint32_t, std::uint32_t>, 4> positions{{
          {x - dx, y}, {x + dx, y}, {x, y - dy}, {x, y + dy}}};
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
  if (width < 2 || height < 2 || raw.imgdata.idata.filters <= 1000 || raw.is_fuji_rotated()) {
    return BayerPattern::Unknown;
  }
  const auto role = [&](std::uint32_t x, std::uint32_t y) {
    const auto c = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
    return c >= 0 && c < 5 ? raw.imgdata.idata.cdesc[c] : '\0';
  };
  const std::array<char, 4> top_left{{role(0, 0), role(1, 0), role(0, 1),
                                       role(1, 1)}};
  // LibRaw's packed filter word spans eight rows. A matching corner alone
  // does not prove a 2x2 CFA, even for layouts stored in that packed word.
  for (unsigned y = 0; y < 8; ++y)
    for (unsigned x = 0; x < 2; ++x)
      if (role(x, y) != top_left[(y % 2) * 2 + x]) return BayerPattern::Unknown;
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

RawLensMetadata probe_raw_lens_metadata(const std::filesystem::path& path) {
  LibRaw raw;
  check_raw(raw.open_file(path.c_str()), "LibRaw metadata open");
  const std::string lens = raw.imgdata.lens.Lens[0] ? raw.imgdata.lens.Lens
                                                  : raw.imgdata.lens.makernotes.Lens;
  return {safe_string(raw.imgdata.idata.make), safe_string(raw.imgdata.idata.model),
          lens, raw.imgdata.other.focal_len,
          raw.imgdata.other.aperture};
}

std::array<float, 4> raw_clip_references(const CallbackLibRaw& raw,
                                        const RawCallbackContext& context,
                                        unsigned x, unsigned y) {
  std::array<float, 4> clip{};
  for (unsigned c = 0; c < 4; ++c) clip[c] = 65535.0F * context.applied_multipliers[c];
  if (!context.lens_shading) return clip;
  const auto& calibration = *context.calibration;
  for (unsigned c = 0; c < context.shading_channels; ++c) {
    unsigned dx = 0, dy = 0;
    if (context.shading_step == 2)
      for (unsigned sy = 0; sy < 2; ++sy)
        for (unsigned sx = 0; sx < 2; ++sx)
          if (context.shading_cfa[((y * 2 + sy) % context.cfa_period) * context.cfa_period +
                                  (x * 2 + sx) % context.cfa_period] == c) {
            dx = sx; dy = sy;
          }
    const auto [sx, sy] = calibration_working_site(raw, calibration,
        x * context.shading_step + dx, y * context.shading_step + dy);
    const float gain = bilinear_gain(*context.lens_shading,
        calibration.sensor.width > 1 ? static_cast<float>(sx) / (calibration.sensor.width - 1U) : 0.0F,
        calibration.sensor.height > 1 ? static_cast<float>(sy) / (calibration.sensor.height - 1U) : 0.0F,
        context.shading_planes[c]);
    clip[c] *= gain / context.lens_shading_scale;
  }
  // A mixed green uses the earliest of its two sensor clip references, for
  // both seeding and restoration. This does not undo the mixed sensor values.
  if (raw.imgdata.idata.colors == 3 && context.shading_channels == 4)
    clip[1] = std::min(clip[1], clip[3]);
  return clip;
}

void raw_highlights_after_interpolate_callback(void* object) {
  auto& raw = *static_cast<CallbackLibRaw*>(object);
  auto& context = *current_raw_callback_context;
  raw.apply_default_median_filter();
  const unsigned channels = raw.imgdata.idata.colors;
  if (channels < 3 || channels > 4) return;
  const auto width = static_cast<unsigned>(raw.imgdata.sizes.width);
  const auto height = static_cast<unsigned>(raw.imgdata.sizes.height);
  context.geometry = {static_cast<unsigned>(raw.is_fuji_rotated()), raw.sample_step(),
                      raw.imgdata.sizes.pixel_aspect, raw.imgdata.sizes.flip};
  context.camera = FloatImage(width, height, channels);
  parallel_for_rows(height, [&](unsigned y) {
    for (unsigned x = 0; x < width; ++x) {
      const auto i = static_cast<std::size_t>(y) * width + x;
      for (unsigned c = 0; c < channels; ++c)
        context.camera.pixels[i * channels + c] = raw.imgdata.image[i][c];
    }
  });
  if (context.reconstruct_highlights) {
    std::array<float, 4> base_clip{};
    for (unsigned c = 0; c < 4; ++c) base_clip[c] = 65535.0F * context.applied_multipliers[c];
    codec::reconstruct_highlight_channels(context.camera, 4U / raw.sample_step(), base_clip,
        [&](unsigned x, unsigned y) { return raw_clip_references(raw, context, x, y); });
    return;
  }
  if (!context.blend_highlights) return;
  parallel_for_rows(height, [&](unsigned y) {
    for (unsigned x = 0; x < width; ++x) {
      const auto references = raw_clip_references(raw, context, x, y);
      const float clip = *std::min_element(references.begin(), references.begin() + channels);
      auto* pixel = context.camera.pixels.data() + (static_cast<std::size_t>(y) * width + x) * channels;
      std::array<float, 4> camera{};
      for (unsigned c = 0; c < channels; ++c) camera[c] = pixel[c];
      codec::blend_highlight_chroma(camera, channels, clip);
      for (unsigned c = 0; c < channels; ++c)
        pixel[c] = camera[c];
    }
  });
}

namespace codec {

DecodedImage decode_raw(const std::filesystem::path& path,
                        const RawDecodeOptions& options) {
  validate_raw_options(options);
  const auto linearization_lut =
      read_linearization_lut(options.linearization_lut);
  const auto lens_shading = read_lens_shading_map(options.lens_shading_map);

  CallbackLibRaw raw;
  // Parameters that affect camera WB/matrix selection must be configured before
  // open_file(), when LibRaw copies camera calibration data into the pipeline.
  auto& params = raw.imgdata.params;
  params.use_camera_wb = 1;
  params.use_auto_wb = 0;
  params.use_camera_matrix = 1;
  params.no_auto_bright = 1;
  params.bright = 1.0F;
  params.output_bps = 16;
  params.half_size = options.half_size ? 1 : 0;
  // Camera RGB, no matrix. LibRaw applies an output matrix in 16-bit integers,
  // truncating and clamping every component to [0, 65535], which cuts off
  // highlight headroom and leaves no place to choose how colours outside the
  // gamut are handled. The camera matrix is applied below, in float.
  params.output_color = 0;
  params.gamm[0] = 1.0;
  params.gamm[1] = 1.0;
  params.use_p1_correction = 1;
  // Complete geometry on float camera samples after LibRaw. Its integer output
  // would clip reconstructed highlights and truncate interpolation fractions.
  params.use_fuji_rotate = 0;
  switch (options.highlight_recovery) {
    case HighlightRecovery::Clip: params.highlight = 0; break;
    case HighlightRecovery::Unclip: params.highlight = 1; break;
    // Keep LibRaw's highlight-preserving WB scale, then recover in our callback
    // with local calibrated clip references instead of fixed thresholds.
    case HighlightRecovery::Blend: params.highlight = 1; break;
    case HighlightRecovery::Reconstruct: params.highlight = 1; break;
  }
  // Correct channel overflow before demosaic; this is specifically intended to
  // prevent artefacts such as magenta clouds.
  params.adjust_maximum_thr = options.profile.empty() ? 0.75F : 0.0F;
  check_raw(raw.open_file(path.c_str()), "LibRaw open");
  std::shared_ptr<const DcpProfile> external_profile;
  if (!options.profile.empty()) {
    auto profile = read_dcp_profile(options.profile);
    if (!dcp_matches_camera(profile, raw.imgdata.idata.make, raw.imgdata.idata.model))
      throw std::invalid_argument("DCP camera does not match RAW: " + profile.camera_model);
    if (raw.imgdata.idata.colors != 3 || raw.imgdata.color.as_shot_wb_applied)
      throw std::invalid_argument("DCP requires three-channel RAW without pre-applied white balance");
    external_profile = std::make_shared<const DcpProfile>(std::move(profile));
  }


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
  check_raw(raw.unpack(), "LibRaw unpack");
  const std::string color_matrix = raw.color_matrix_source();
  // Without a matrix camera RGB stands in for ProPhoto, so every colour is
  // uncalibrated even though the decode itself succeeds.
  if (color_matrix == "none") mark_degraded("no_camera_matrix");
  // A DNG's opcode lists belong to its raw data: bad pixels it lists, and the
  // lens shading its gain maps correct, are part of what the file describes.
  // One this decoder cannot apply, unless the file marks it optional, leaves
  // the image short of that description.
  auto opcodes = read_dng_opcodes(raw);
  const bool embedded_vignette = !opcodes[1].gain_maps.empty();
  bool opcodes_skipped = !apply_dng_bad_pixels(raw, opcodes[0]);
  bool opcodes_malformed = false;
  for (const auto& list : opcodes) {
    opcodes_skipped = opcodes_skipped || !list.skipped_required.empty();
    opcodes_malformed = opcodes_malformed || list.malformed;
  }
  if (opcodes_malformed) mark_degraded("dng_opcode_list_malformed");
  if (opcodes_skipped) mark_degraded("dng_opcode_unsupported");
  const auto calibration =
      prepare_calibration(raw, linearization_lut, options, std::move(opcodes[1].gain_maps));
  apply_bad_pixel_map(raw, options.bad_pixel_map);
  if (options.auto_bad_pixel_correction) correct_auto_bad_pixels(raw);
  apply_code_calibration(raw, calibration);
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
  const auto cropped_sensor = raw.sensor_geometry();
  if ((!linearization_lut.samples.empty() || !calibration.dark.empty() ||
       !calibration.gain_maps.empty() || !lens_shading.gains.empty()) &&
      (cropped_sensor.left < calibration.sensor.left || cropped_sensor.top < calibration.sensor.top ||
       cropped_sensor.left + cropped_sensor.width > calibration.sensor.left + calibration.sensor.width ||
       cropped_sensor.top + cropped_sensor.height > calibration.sensor.top + calibration.sensor.height)) {
    throw std::invalid_argument("RAW crop extends outside the calibration's original visible area");
  }
  RawCallbackContext callback_context;
  callback_context.blend_highlights = options.highlight_recovery == HighlightRecovery::Blend;
  callback_context.reconstruct_highlights = options.highlight_recovery == HighlightRecovery::Reconstruct;
  callback_context.calibration = &calibration;
  callback_context.lens_shading = lens_shading.gains.empty() ? nullptr : &lens_shading;
  if (!lens_shading.gains.empty()) {
    const auto [low, high] = lens_shading_gain_range(lens_shading, calibration, raw);
    if (low == high) {
      // A common gain commutes with demosaic and belongs in float. Attenuating
      // the integer mosaic would hide saturation from LibRaw's fixed thresholds.
      callback_context.lens_shading = nullptr;
      callback_context.lens_shading_scale = low;
    } else {
      callback_context.lens_shading_scale = std::max(1.0F, high);
    }
  }
  {
    RawCallbackScope callback_scope(callback_context);
    raw.set_pre_preinterpolate_callback(raw_pre_preinterpolate_callback);
    raw.set_post_interpolate_callback(raw_highlights_after_interpolate_callback);
    check_raw(raw.dcraw_process(), "LibRaw demosaic");
  }
  const float exposure_gain = callback_context.exposure_gain * callback_context.lens_shading_scale;
  if (callback_context.camera.pixels.empty())
    throw std::runtime_error("LibRaw did not expose a three- or four-channel camera raster");

  DecodedImage result;
  decode.delivered_crop_left = raw.imgdata.sizes.left_margin;
  decode.delivered_crop_top = raw.imgdata.sizes.top_margin;
  result.decode = std::move(decode);
  // The one scene-referred producer in the codebase. Nothing below has applied
  // a rendering intent, so 1.0 here is wherever white balance happened to land
  // rather than diffuse white, and the renderer owns the exposure decision.
  result.domain = InputDomain::kSceneReferred;
  const float camera_wb = raw.imgdata.color.cam_mul[0];
  if (raw.imgdata.color.as_shot_wb_applied && camera_wb > 0.00001F) {
    result.raw_white_balance = "camera-applied";
  } else if (camera_wb > 0.00001F &&
             !(raw.imgdata.process_warnings & LIBRAW_WARN_BAD_CAMERA_WB)) {
    result.raw_white_balance = "camera";
  } else if (camera_wb < -0.5F || (camera_wb <= 0.00001F &&
             !(raw.imgdata.rawparams.options & LIBRAW_RAWOPTIONS_CAMERAWB_FALLBACK_TO_DAYLIGHT))) {
    result.raw_white_balance = "auto";
  } else {
    result.raw_white_balance = "daylight";
  }
  result.raw_color_matrix = color_matrix;
  result.linear_p3 = std::move(callback_context.camera);
  const auto dng_matrix = color_matrix == "embedded"
                              ? dng_camera_matrix(raw, callback_context.applied_multipliers)
                              : std::nullopt;
  std::optional<DngColorTransform> profile_transform;
  if (external_profile) {
    auto color_profile = external_profile->color;
    if (raw.imgdata.idata.dng_version != 0) {
      for (unsigned c = 0; c < 3; ++c) {
        const auto v = raw.imgdata.color.dng_levels.analogbalance[c];
        color_profile.analog_balance[c] = std::isfinite(v) && v > 0 ? v : 1.0;
      }
      if (raw.camera_calibration_matches_signature(external_profile->calibration_signature)) {
        for (unsigned k = 0; k < 2; ++k) {
          Matrix3d camera_calibration{};
          bool present = false;
          for (unsigned i = 0; i < 3; ++i) for (unsigned j = 0; j < 3; ++j) {
            camera_calibration[i][j] = raw.imgdata.color.dng_color[k].calibration[i][j];
            present = present || camera_calibration[i][j] != 0;
          }
          if (present) color_profile.calibrations[k].camera_calibration = camera_calibration;
        }
      }
    }
    std::array<double, 3> neutral{};
    for (unsigned c = 0; c < 3; ++c)
      neutral[c] = 1.0 / callback_context.applied_multipliers[c];
    profile_transform = dng_camera_color_transform(color_profile, neutral);
    if (!profile_transform) throw std::invalid_argument("DCP has an unusable camera color transform");
    auto context = std::make_shared<DcpRenderContext>();
    context->profile = external_profile;
    context->illuminant_weight = profile_transform->illuminant_weight;
    const float baseline = raw.imgdata.color.dng_levels.baseline_exposure;
    // LibRaw uses -999 for an absent BaselineExposure (including native ARW).
    context->baseline_exposure = std::isfinite(baseline) && baseline != -999.0F
                                     ? baseline : 0.0F;
    result.raw_profile = std::move(context);
    result.raw_profile_path = std::filesystem::absolute(options.profile);
    result.raw_color_matrix = "dcp";
  }
  const auto columns = camera_to_ap1_columns(raw, color_matrix != "none", dng_matrix);
  const float scale = exposure_gain * options.digital_gain / 65535.0F;
  const auto channels = static_cast<std::size_t>(result.linear_p3.channels);
  // Camera RGB is never negative, so these limits cover every colour this
  // camera's matrix can produce.
  const auto compression = gamut_compression_scales(gamut_compression_limits(columns, channels));

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
  // LibRaw exposes the three settings the renderer needs and none of the six a
  // level model reads: there is no exposure compensation in its `other` block and
  // no presence anywhere. The file's own Exif is read instead, so a RAW reaches
  // the model with the same capture vector a JPEG of the same frame would.
  codec::apply_capture_parameters_from_file(result, path);
  // Provenance follows the same source where LibRaw had nothing. Its maker-note
  // block is empty for the 35 mm-equivalent length on some bodies while the Exif
  // tag is right there, and a rendered file that cannot state the capture its own
  // model read is a file whose provenance is weaker than its result.
  const auto& parsed = result.metadata.capture;
  if (result.metadata.iso == 0 && parsed.iso && *parsed.iso > 0.0) {
    result.metadata.iso = static_cast<std::uint32_t>(std::min(
        *parsed.iso, static_cast<double>(std::numeric_limits<std::uint32_t>::max())));
  }
  if (!(result.metadata.exposure_seconds > 0.0) && parsed.exposure_seconds) {
    result.metadata.exposure_seconds = *parsed.exposure_seconds;
  }
  if (!(result.metadata.aperture > 0.0) && parsed.f_number) {
    result.metadata.aperture = *parsed.f_number;
  }
  if (!(result.metadata.focal_length_mm > 0.0) && parsed.focal_length_mm) {
    result.metadata.focal_length_mm = *parsed.focal_length_mm;
  }
  if (!(result.metadata.focal_length_35mm > 0.0) && parsed.focal_length_35mm) {
    result.metadata.focal_length_35mm = *parsed.focal_length_35mm;
  }
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
  const int sensor_flip = raw.imgdata.sizes.flip;
  // All metadata and camera coefficients have been copied. Release LibRaw
  // before float geometry allocates a destination, keeping two image buffers
  // as the maximum geometry working set.
  raw.recycle();
  result.linear_p3 = apply_raw_output_geometry(std::move(result.linear_p3), callback_context.geometry);
  result.decode.decoded_width = result.linear_p3.width;
  result.decode.decoded_height = result.linear_p3.height;
  parallel_for_rows(result.linear_p3.height, [&](const std::uint32_t y) {
    const auto row_start = static_cast<std::size_t>(y) * result.linear_p3.width;
    for (std::uint32_t x = 0; x < result.linear_p3.width; ++x) {
      const auto output_index = row_start + x;
      const auto input_index = output_index * channels;
      std::array<float, 4> camera{};
      for (std::size_t c = 0; c < channels; ++c) {
        camera[c] = result.linear_p3.pixels[input_index + c] * scale;
      }
      if (profile_transform) {
        // Preserve scene values outside P3 for DCP development in ProPhoto.
        // The existing native gamut compressor is intentionally after this branch.
        for (unsigned i = 0; i < 3; ++i) {
          const auto& row = profile_transform->camera_to_p3[i];
          result.linear_p3.pixels[output_index * channels + i] = static_cast<float>(
              row[0] * camera[0] + row[1] * camera[1] + row[2] * camera[2]);
        }
        continue;
      }
      // A camera matrix extrapolates some saturated colours past the spectral
      // locus. Narrow-band blue light lands at zero or negative luminance
      // there, which the renderer shows as black, and clamping the negative
      // components (as LibRaw's integer output did at ProPhoto's boundary)
      // leaves it nearly black with its hue shifted. Compression instead pulls
      // components that reach past P3 toward the largest one, so every camera
      // colour ends inside AP1 and colours inside P3 are untouched. Values
      // above one are highlight headroom and pass through.
      std::array<float, 3> ap1{};
      for (std::size_t i = 0; i < 3; ++i) {
        ap1[i] = columns[0][i] * camera[0] + columns[1][i] * camera[1] +
                 columns[2][i] * camera[2] + columns[3][i] * camera[3];
      }
      const auto inside = compress_gamut(ap1[0], ap1[1], ap1[2], compression);
      const auto p3 = ap1_d65_to_linear_p3(inside[0], inside[1], inside[2]);
      result.linear_p3.pixels[output_index * channels] = p3[0];
      result.linear_p3.pixels[output_index * channels + 1] = p3[1];
      result.linear_p3.pixels[output_index * channels + 2] = p3[2];
    }
  });
  if (channels == 4) {
    // Compact only after all parallel pixel transforms finish. Four-to-three
    // compaction during row processing would overwrite another row's input.
    const auto count = static_cast<std::size_t>(result.linear_p3.width) * result.linear_p3.height;
    for (std::size_t i = 0; i < count; ++i)
      for (unsigned c = 0; c < 3; ++c)
        result.linear_p3.pixels[i * 3 + c] = result.linear_p3.pixels[i * 4 + c];
    result.linear_p3.channels = 3;
    result.linear_p3.pixels.resize(count * 3);
  }
  if (!options.lens_profile.empty()) {
    auto profile = read_lens_profile(options.lens_profile);
    // An embedded gain map has already calibrated this RAW's lens shading.
    if (embedded_vignette || !lens_shading.gains.empty())
      for (auto& c : profile.calibrations) c.vignette.reset();
    result.raw_lens_correction = apply_lens_profile(result.linear_p3, profile,
        result.metadata.focal_length_mm, result.metadata.aperture, sensor_flip);
    result.raw_lens_profile_path = std::filesystem::absolute(options.lens_profile);
  }
  // Float output geometry has applied the sensor orientation; encoded pixels are top-left.
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
  params.use_fuji_rotate = 0;
  params.adjust_maximum_thr = 0.0F;
  params.half_size = 0;
  params.use_p1_correction = 1;

  check_raw(raw.open_file(path.c_str()), "LibRaw open RAW mosaic");
  const auto& sizes = raw.imgdata.sizes;
  const std::uint64_t width = sizes.width;
  const std::uint64_t height = sizes.height;
  const std::uint64_t sensor_width =
      sizes.raw_width ? sizes.raw_width : sizes.width;
  const std::uint64_t sensor_height =
      sizes.raw_height ? sizes.raw_height : sizes.height;
  if (!codec::raw_input_budget_ok(sensor_width, sensor_height) ||
      !codec::raw_input_budget_ok(width, height)) {
    throw std::runtime_error(
        "RAW sensor raster " + std::to_string(sensor_width) + "x" +
        std::to_string(sensor_height) +
        " exceeds the supported 240869376-pixel input limit");
  }
  check_raw_memory_admission(sensor_width, sensor_height, width, height);
  if (detect_bayer_pattern(raw, static_cast<unsigned>(width), static_cast<unsigned>(height)) ==
      BayerPattern::Unknown) {
    throw std::invalid_argument("RAW mosaic requires a 2x2 Bayer CFA (X-Trans is not packable)");
  }
  check_raw(raw.unpack(), "LibRaw unpack RAW mosaic");
  auto opcodes = read_dng_opcodes(raw);
  static_cast<void>(apply_dng_bad_pixels(raw, opcodes[0]));
  const auto calibration =
      prepare_calibration(raw, linearization_lut, options, std::move(opcodes[1].gain_maps));
  apply_bad_pixel_map(raw, options.bad_pixel_map);
  if (options.auto_bad_pixel_correction) correct_auto_bad_pixels(raw);
  apply_code_calibration(raw, calibration);

  std::vector<std::uint16_t> captured;
  std::uint32_t captured_width = 0;
  std::uint32_t captured_height = 0;
  // pre_interpolate() can merge the green channel indices even with
  // no_interpolation set. Preserve the original CFA calibration plane first.
  std::array<unsigned, 4> shading_planes{};
  if (!lens_shading.gains.empty())
    for (unsigned y = 0; y < 2; ++y)
      for (unsigned x = 0; x < 2; ++x)
        shading_planes[y * 2 + x] = lsc_channel_for_cfa(
            raw, static_cast<unsigned>(raw.COLOR(y, x)), lens_shading.channels);
  RawCallbackContext callback_context;
  callback_context.captured_mosaic = &captured;
  callback_context.captured_width = &captured_width;
  callback_context.captured_height = &captured_height;
  {
    RawCallbackScope callback_scope(callback_context);
    raw.set_pre_converttorgb_callback(raw_capture_before_rgb_callback);
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
      const auto index = static_cast<std::size_t>(y) * captured_width + x;
      float shading_gain = 1.0F;
      if (!lens_shading.gains.empty()) {
        const auto [sx, sy] = calibration_site(raw, calibration, x, y, 0);
        shading_gain = bilinear_gain(lens_shading,
            calibration.sensor.width > 1 ? static_cast<float>(sx) / (calibration.sensor.width - 1U) : 0.0F,
            calibration.sensor.height > 1 ? static_cast<float>(sy) / (calibration.sensor.height - 1U) : 0.0F,
            shading_planes[(y % 2) * 2 + x % 2]);
      }
      // This path never demosaics: preserve the captured sensor precision and
      // apply calibration directly in float, without a max-gain round trip.
      result.samples.at(x, y, 0) =
          static_cast<float>(captured[index]) / white * options.digital_gain *
          shading_gain;
    }
  }
  return result;
}

}  // namespace hyperdr

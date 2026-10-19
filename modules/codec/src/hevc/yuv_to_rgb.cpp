#include <algorithm>
#include <cmath>
#include <cstring>

#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/raster_budget.hpp"
#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
#include <atomic>
#include "hevc/testing.hpp"
#endif
namespace hyperdr::codec::hevc {
#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
namespace testing {
namespace {
std::atomic<bool> nearest_chroma{false}, rounded_chroma{false}, integer_rgb{false};
}
void set_nearest_chroma(bool nearest) { nearest_chroma.store(nearest); }
void set_rounded_chroma(bool rounded) { rounded_chroma.store(rounded); }
void set_integer_rgb(bool integer) { integer_rgb.store(integer); }
}  // namespace testing
#endif
unsigned DecodedPicture::chroma_width() const noexcept {
  return chroma_format == 0 ? 0
                            : (width + (chroma_format < 3 ? 1 : 0)) / (chroma_format < 3 ? 2 : 1);
}
unsigned DecodedPicture::chroma_height() const noexcept {
  return chroma_format == 0
             ? 0
             : (height + (chroma_format == 1 ? 1 : 0)) / (chroma_format == 1 ? 2 : 1);
}
namespace {
unsigned code_at(const std::vector<std::uint8_t>& bytes, std::size_t index,
                 unsigned depth) noexcept {
  if (depth == 8) return bytes[index];
  std::uint16_t value;
  std::memcpy(&value, bytes.data() + index * 2, 2);
  return value >> 6;
}
double chroma_sample(const DecodedPicture& p, unsigned x, unsigned y, bool cr, unsigned location) {
  const unsigned sx = p.chroma_format < 3 ? 2 : 1, sy = p.chroma_format == 1 ? 2 : 1;
#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
  // Compiled only into heif_input_probe, never the codec library or app.
  // Changes only the interpolation for the old-path attribution audit.
  if (testing::nearest_chroma.load())
    return cr ? p.cr_at(x / sx, y / sy) : p.cb_at(x / sx, y / sy);
#endif
  // H.265 E.2.1: 0/2/4 horizontal co-sited; 1/3/5 half a luma sample.
  const double ox = sx == 1 ? 0 : (location & 1 ? .5 : 0);
  const double oy = sy == 1 ? 0 : (location < 2 ? .5 : location < 4 ? 0 : 1);
  const double fx = std::clamp((double(x) - ox) / sx, 0.0, double(p.chroma_width() - 1));
  const double fy = std::clamp((double(y) - oy) / sy, 0.0, double(p.chroma_height() - 1));
  const auto x0 = static_cast<unsigned>(fx), y0 = static_cast<unsigned>(fy);
  const auto x1 = std::min(x0 + 1, p.chroma_width() - 1),
             y1 = std::min(y0 + 1, p.chroma_height() - 1);
  const auto read = [&](unsigned xx, unsigned yy) {
    return double(cr ? p.cr_at(xx, yy) : p.cb_at(xx, yy));
  };
  const auto a = read(x0, y0) + (read(x1, y0) - read(x0, y0)) * (fx - x0);
  const auto b = read(x0, y1) + (read(x1, y1) - read(x0, y1)) * (fx - x0);
  const auto interpolated = a + (b - a) * (fy - y0);
#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
  if (testing::rounded_chroma.load()) return std::floor(interpolated + .5);
#endif
  return interpolated;
}
}  // namespace
unsigned DecodedPicture::luma_at(unsigned x, unsigned y) const noexcept {
  return code_at(luma, std::size_t(y) * width + x, bit_depth);
}
unsigned DecodedPicture::cb_at(unsigned x, unsigned y) const noexcept {
  return code_at(chroma, (std::size_t(y) * chroma_width() + x) * 2, bit_depth);
}
unsigned DecodedPicture::cr_at(unsigned x, unsigned y) const noexcept {
  return code_at(chroma, (std::size_t(y) * chroma_width() + x) * 2 + 1, bit_depth);
}
YuvRgbParams conversion_params(const HvcConfig& config, const HeifNclx* nclx) {
  YuvRgbParams out;
  const HeifNclx* color = nclx ? nclx : config.vui_color ? &*config.vui_color : nullptr;
  if (color) {
    out.matrix = color->matrix;
    out.full_range = color->full_range;
  }
  out.chroma_location = config.chroma_location_top.value_or(1);
  return out;
}
void yuv_to_rgb(const DecodedPicture& p, const YuvRgbParams& params, const RgbFloatRowSink& sink) {
  CancelScope cancellation(params.cancel ? params.cancel : current_cancel_token);
  check_cancelled();
  if (!sink || !raster_geometry_ok(p.width, p.height) ||
      (p.bit_depth != 8 && p.bit_depth != 10) || p.chroma_format > 3 ||
      params.chroma_location > 5 || p.luma.size() != p.luma_row_bytes() * p.height ||
      p.chroma.size() != p.chroma_row_bytes() * p.chroma_height())
    throw std::invalid_argument("invalid YUV conversion planes or parameters");
  const int matrix = params.matrix == 2 ? 6 : params.matrix;
  double kr = 0, kb = 0;
  switch (matrix) {
    case 0:
      break;
    case 1:
      kr = .2126;
      kb = .0722;
      break;
    case 5:
    case 6:
      kr = .299;
      kb = .114;
      break;
    case 9:
      kr = .2627;
      kb = .0593;
      break;
    default:
      throw HeifReadError("unsupported HEIF YUV matrix", "color_matrix");
  }
  const double maximum = (1U << p.bit_depth) - 1, scale = 1U << (p.bit_depth - 8);
  const double offset = params.full_range ? 0 : 16 * scale;
  const double yrange = params.full_range ? maximum : 219 * scale;
  const double crange = params.full_range ? maximum : 224 * scale;
  const double center = 1U << (p.bit_depth - 1);
  const auto encoded = [&](double value) {
#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
    if (testing::integer_rgb.load())
      value = std::floor(std::clamp(value, 0.0, 1.0) * maximum + .5) / maximum;
#endif
    return static_cast<float>(value);
  };
  const auto row = [&](unsigned y) {
    check_cancelled();
    std::vector<float> rgb(std::size_t(p.width) * 3);
    for (unsigned x = 0; x < p.width; ++x) {
      const double yy = (double(p.luma_at(x, y)) - offset) / yrange;
      double r = yy, g = yy, b = yy;
      if (p.chroma_format) {
        const auto cb = chroma_sample(p, x, y, false, params.chroma_location),
                   cr = chroma_sample(p, x, y, true, params.chroma_location);
        if (matrix == 0) {
          r = (cr - offset) / yrange;
          b = (cb - offset) / yrange;
        } else {
          const auto u = (cb - center) / crange, v = (cr - center) / crange;
          r = yy + 2 * (1 - kr) * v;
          b = yy + 2 * (1 - kb) * u;
          g = (yy - kr * r - kb * b) / (1 - kr - kb);
        }
      }
      rgb[x * 3] = encoded(r);
      rgb[x * 3 + 1] = encoded(g);
      rgb[x * 3 + 2] = encoded(b);
    }
    sink(y, rgb);
  };
  if (params.parallel_rows)
    parallel_for_rows(p.height, row);
  else
    for (unsigned y = 0; y < p.height; ++y) row(y);
}
}  // namespace hyperdr::codec::hevc

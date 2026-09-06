#include "hyperdr/gainmap/display_referred.hpp"
#include "local_gain.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

// Below this the log is meaningless and would be evaluated on noise. Roughly
// twenty stops under diffuse white.
constexpr float kMinimumLuminance = 1.0e-6F;

// Exposure for an input that already carries a photographic decision.
//
// Automatic exposure is deliberately not consulted. Its input is the scene's
// log average, and on a finished picture that measures the photographer's grade
// rather than the scene, so letting it run would move someone else's midtones.
// A manual --exposure is still honoured, because it is an explicit instruction,
// and --exposure-bias is added on top exactly as it is elsewhere.
float display_referred_exposure_ev(const GainMapOptions& options) {
  const float selected =
      options.auto_exposure ? 0.0F : clamp_finite(options.exposure_ev, -10.0F, 10.0F);
  return clamp_finite(selected + options.exposure_bias_ev, -10.0F, 10.0F);
}

// shoulder_start is validated to [0.18, 0.75] and is the documented control for
// "linear SDR level where HDR expansion begins", which is exactly what the knee
// is here: below it the base and the HDR rendition are the same picture.
float knee_linear(const GainMapOptions& options) {
  return std::clamp(options.look.shoulder_start, 0.18F, 0.75F);
}

// The ceiling that lands `peak` exactly on `target`.
//
// The shoulder only approaches its ceiling, so using the target as the ceiling
// directly leaves the brightest pixel short of it -- with a 1.06-stop input and
// a 1.06-stop budget the rendition came out at 0.42 stops, which under-restored
// the highlights and, because the ISO metadata declares the gain interval as
// the alternate headroom, shrank the declared range on every re-export
// (2.08x -> 1.34x -> 1.09x). Choosing the ceiling instead of assuming it keeps
// the knee C1 and still uses the whole budget.
//
// `display_shoulder_log2(peak, knee, C)` rises monotonically from `knee` toward
// `peak` as C goes from `knee` to infinity, so any target strictly between them
// is reachable and bisection finds it.
float ceiling_for_target(float knee, float peak, float target) {
  float low = knee + 1.0e-4F;
  float high = knee + 1.0F;
  for (int i = 0; i < 60 && display_shoulder_log2(peak, knee, high) < target; ++i) {
    high = knee + (high - knee) * 2.0F;
  }
  for (int i = 0; i < 64; ++i) {
    const float mid = 0.5F * (low + high);
    if (display_shoulder_log2(peak, knee, mid) < target) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return 0.5F * (low + high);
}

// Per-cell mean of the per-pixel gain: the gain map downsampled, rather than
// the gain of the downsampled image.
//
// The difference matters at a specular. Evaluating the curve at a cell's mean
// luminance asks what its *typical* pixel needs, so a small bright region in a
// dark cell is averaged away and never restored; averaging the gain each pixel
// actually asks for pulls the cell up in proportion to how much of it is
// bright, which is what a low-frequency map can honestly represent.
struct CellGains {
  GainGridDimensions dimensions;
  std::vector<float> stops;
};

template <typename PixelGain>
CellGains measure_cell_gains(const FloatImage& source, float exposure,
                             PixelGain gain_of,
                             std::vector<float>* luminance_guide = nullptr) {
  CellGains cells;
  cells.dimensions = choose_gain_dimensions(source);
  cells.stops.assign(static_cast<std::size_t>(cells.dimensions.width) *
                         cells.dimensions.height,
                     0.0F);
  if (luminance_guide) luminance_guide->resize(cells.stops.size());
  parallel_for_rows(cells.dimensions.height, [&](const std::uint32_t gy) {
    const std::uint32_t y0 =
        grid_cell_edge(gy, source.height, cells.dimensions.height);
    const std::uint32_t y1 = std::min(
        source.height,
        std::max(y0 + 1U, grid_cell_edge(gy + 1U, source.height,
                                         cells.dimensions.height)));
    for (std::uint32_t gx = 0; gx < cells.dimensions.width; ++gx) {
      const std::uint32_t x0 =
          grid_cell_edge(gx, source.width, cells.dimensions.width);
      const std::uint32_t x1 = std::min(
          source.width,
          std::max(x0 + 1U, grid_cell_edge(gx + 1U, source.width,
                                           cells.dimensions.width)));
      double total = 0.0, guide_total = 0.0;
      std::size_t samples = 0;
      for (std::uint32_t y = y0; y < y1; ++y) {
        for (std::uint32_t x = x0; x < x1; ++x) {
          const std::size_t index =
              (static_cast<std::size_t>(y) * source.width + x) * 3;
          const float luminance = p3_luminance(positive_finite(source.pixels[index]),
                           positive_finite(source.pixels[index + 1]),
                           positive_finite(source.pixels[index + 2])) *
              exposure;
          total += gain_of(luminance);
          if (luminance_guide) guide_total += luminance;
          ++samples;
        }
      }
      cells.stops[static_cast<std::size_t>(gy) * cells.dimensions.width + gx] =
          samples == 0 ? 0.0F : static_cast<float>(total / samples);
      if (luminance_guide) {
        (*luminance_guide)[static_cast<std::size_t>(gy) * cells.dimensions.width + gx] =
            samples == 0 ? 0.0F : static_cast<float>(guide_total / samples);
      }
    }
  });
  return cells;
}

struct QuantizedGrid {
  FloatImage codes;
  float stored_gain_max{0.0F};
  float stored_gamma{1.0F};
  Rational gain_max_metadata{0, 1};
  Rational gamma_metadata{1, 1};
};

// Same 8-bit encoding the photographic writer uses: normalise by the grid's own
// maximum, pick the gamma that minimises round-trip error over that
// distribution, and store the rounded code.
QuantizedGrid quantize_grid(const std::vector<float>& gain_stops,
                            const GainGridDimensions& dimensions) {
  QuantizedGrid quantized;
  const std::size_t count = gain_stops.size();
  float gain_max = 0.0F;
  for (const float value : gain_stops) gain_max = std::max(gain_max, value);

  std::vector<float> normalized(count, 0.0F);
  if (gain_max > kEpsilon) {
    for (std::size_t i = 0; i < count; ++i) {
      normalized[i] = std::clamp(gain_stops[i] / gain_max, 0.0F, 1.0F);
    }
  }
  const float gamma = gain_max > kEpsilon ? choose_gain_gamma(normalized) : 1.0F;
  quantized.gain_max_metadata = rational_from_float(gain_max);
  quantized.gamma_metadata = rational_from_float(gamma);
  quantized.stored_gain_max =
      static_cast<float>(quantized.gain_max_metadata.numerator) /
      static_cast<float>(quantized.gain_max_metadata.denominator);
  quantized.stored_gamma =
      static_cast<float>(quantized.gamma_metadata.numerator) /
      static_cast<float>(quantized.gamma_metadata.denominator);

  quantized.codes = FloatImage(dimensions.width, dimensions.height, 1);
  for (std::size_t i = 0; i < count; ++i) {
    const float code = encode_gain_code(normalized[i], quantized.stored_gamma);
    const auto x = static_cast<std::uint32_t>(i % dimensions.width);
    const auto y = static_cast<std::uint32_t>(i / dimensions.width);
    const float stored = quantize_gain_code_dithered(code, x, y);
    quantized.codes.pixels[i] = stored;
  }
  return quantized;
}

// Fits a base pixel into [0, 1] by reducing saturation only.
//
// Reached only where a channel overflows even though the luminance the tone
// curve chose does not -- a saturated highlight, where the brightest channel
// can sit several times above the pixel's luminance. Pulling the pixel towards
// its own luminance is the minimal correction: it keeps the level the curve
// asked for and the hue, and gives up only the chroma that has nowhere to go.
// Clamping each channel independently would shift the hue instead, and scaling
// all three would darken a highlight the curve had deliberately placed.
std::array<float, 3> fit_to_unit_cube(std::array<float, 3> rgb) {
  const float peak = std::max({rgb[0], rgb[1], rgb[2]});
  if (!(peak > 1.0F)) {
    return {std::clamp(rgb[0], 0.0F, 1.0F), std::clamp(rgb[1], 0.0F, 1.0F),
            std::clamp(rgb[2], 0.0F, 1.0F)};
  }
  const float luminance = p3_luminance(rgb[0], rgb[1], rgb[2]);
  if (!(luminance < 1.0F) || !std::isfinite(luminance)) return {1.0F, 1.0F, 1.0F};
  const float t = std::clamp((1.0F - luminance) / (peak - luminance), 0.0F, 1.0F);
  return {std::clamp(luminance + t * (rgb[0] - luminance), 0.0F, 1.0F),
          std::clamp(luminance + t * (rgb[1] - luminance), 0.0F, 1.0F),
          std::clamp(luminance + t * (rgb[2] - luminance), 0.0F, 1.0F)};
}

}  // namespace

float display_shoulder_log2(float u, float knee, float ceiling) {
  const float span = ceiling - knee;
  if (!(std::isfinite(span) && span > kEpsilon)) {
    throw std::invalid_argument(
        "display-referred shoulder needs a ceiling above its knee");
  }
  if (!std::isfinite(u)) return u > 0.0F ? ceiling : knee;
  if (u <= knee) return u;
  return ceiling - span * std::exp(std::max(-(u - knee) / span, -80.0F));
}

GainMapResult make_display_referred_sdr_passthrough_result(
    const FloatImage& source, const GainMapOptions& options);

GainMapResult make_display_referred_sdr_result(const FloatImage& source,
                                               const GainMapOptions& options,
                                               const CaptureMetadata& capture,
                                               GainMapPreparation* preparation) {
  if (source.channels != 3) {
    throw std::invalid_argument("gain-map input must be RGB");
  }
  validate_gain_map_options(options);

  // Develop the base once, identically at every gain strength. In particular,
  // crossing zero must not switch a finished photograph to a RAW tone curve.
  GainMapResult result;
  if (preparation && preparation->ready) {
    result.base_linear = preparation->base.base;
    result.stats = preparation->base_stats;
    result.exposure_ev = preparation->exposure_ev;

  } else result = make_display_referred_sdr_passthrough_result(source, options);
  const float requested_stops = options.auto_headroom
      ? options.look.headroom_max_stops
      : std::clamp(options.headroom_stops, 0.0F,
                   options.look.headroom_max_stops);
  if (!(requested_stops > kEpsilon) ||
      (!preparation && !(std::min(options.gain_strength, 1.0F) > kEpsilon))) {
    return result;
  }
  const float knee = knee_linear(options);
  GainMapPreparation owned_preparation;
  auto& prepared = preparation ? *preparation : owned_preparation;
  if (!prepared.ready) {
    std::vector<float> guide;
    const auto cells = measure_cell_gains(result.base_linear, 1.0F, [&](float luma) {
      return requested_stops * smoothstep(knee, 1.0F, luma);
    }, &guide);
    auto local = weight_local_highlights(cells.stops, guide, guide,
                                        cells.dimensions, capture, options.look);
    prepared.width = cells.dimensions.width; prepared.height = cells.dimensions.height;
    prepared.stops = std::move(local.stops);
    prepared.weight_mean = local.weight_mean; prepared.weight_p95 = local.weight_p95;
    if (preparation) prepared.base.base = result.base_linear;
    prepared.base_stats = result.stats; prepared.exposure_ev = result.exposure_ev;
    prepared.ready = true;
  }
  const GainGridDimensions dimensions{prepared.width, prepared.height};
  auto gains = prepared.stops;
  const float strength = std::min(options.gain_strength, 1.0F);
  for (float& gain : gains) gain *= strength;
  auto quantized = quantize_grid(gains, dimensions);
  result.gain_map = std::move(quantized.codes);
  result.metadata.gain_max = quantized.gain_max_metadata;
  result.metadata.alternate_headroom = quantized.gain_max_metadata;
  result.metadata.gamma = quantized.gamma_metadata;
  result.headroom_stops = quantized.stored_gain_max;
  auto& stats = result.stats;
  stats.headroom_stops = requested_stops * strength;
  stats.headroom_linear = std::exp2(stats.headroom_stops);
  stats.gain_max_stops = quantized.stored_gain_max;
  stats.gain_gamma = quantized.stored_gamma;
  stats.local_weight_mean = prepared.weight_mean;
  stats.local_weight_p95 = prepared.weight_p95;
  const GridView gain_view(result.gain_map.pixels, dimensions.width,
                           dimensions.height);
  const BilinearGridSampler sampler(dimensions.width, dimensions.height,
                                    source.width, source.height);
  std::vector<float> peaks(source.height, 1.0F), below(source.height, 0.0F);
  parallel_for_rows(source.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const float sdr = p3_luminance(result.base_linear.at(x, y, 0),
          result.base_linear.at(x, y, 1), result.base_linear.at(x, y, 2));
      const float gain = quantized.stored_gain_max * decode_gain_code(
          sampler.sample(gain_view, x, y),
          quantized.stored_gamma);
      const float hdr = sdr * std::exp2(gain);
      peaks[y] = std::max(peaks[y], hdr);
      if (sdr <= knee) below[y] = std::max(below[y],
          std::abs(hdr - sdr) / std::max(sdr, kEpsilon));
    }
  });
  stats.rendered_peak = *std::max_element(peaks.begin(), peaks.end());
  stats.below_knee_relative_difference_max = *std::max_element(below.begin(), below.end());
  stats.headroom_utilization = stats.headroom_linear > 1.0F
      ? std::clamp((stats.rendered_peak - 1.0F) / (stats.headroom_linear - 1.0F), 0.0F, 1.0F)
      : 0.0F;
  measure_quantized_gain(stats, result.gain_map, quantized.stored_gain_max,
                          quantized.stored_gamma, stats.headroom_stops);
  return result;
}

GainMapResult make_display_referred_sdr_passthrough_result(
    const FloatImage& source, const GainMapOptions& options) {
  if (source.channels != 3) {
    throw std::invalid_argument("gain-map input must be RGB");
  }
  validate_gain_map_options(options);

  const float exposure_ev = display_referred_exposure_ev(options);
  const float exposure = std::exp2(exposure_ev);
  // The shoulder is engaged only when the exposure can actually push the image
  // past 1.0. At unity -- the default, and what the panel always sends -- the
  // base is the input sample for sample, which is the whole point of naming
  // this domain separately. Brightening rolls the excess off instead of
  // clipping it, but never turns it into gain: an SDR input does not acquire
  // highlight range it did not arrive with.
  const bool rolls_off = exposure > 1.0F + kEpsilon;
  const float knee = std::log2(knee_linear(options));
  // The brightened image peaks at `exposure`, since an SDR input tops out at
  // 1.0. Solving for the ceiling lands that peak on 1.0 exactly, so the roll-off
  // spends the whole code range instead of asymptotically approaching it.
  const float ceiling =
      rolls_off ? ceiling_for_target(knee, exposure_ev, 0.0F) : 0.0F;

  GainMapResult result;
  result.base_linear = FloatImage(source.width, source.height, 3);
  std::vector<float> row_peak(source.height, 0.0F);
  parallel_for_rows(source.height, [&](const std::uint32_t y) {
    float peak = 0.0F;
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const std::size_t base =
          (static_cast<std::size_t>(y) * source.width + x) * 3;
      std::array<float, 3> rgb{
          positive_finite(source.pixels[base]) * exposure,
          positive_finite(source.pixels[base + 1]) * exposure,
          positive_finite(source.pixels[base + 2]) * exposure};
      if (rolls_off) {
        const float luminance = p3_luminance(rgb[0], rgb[1], rgb[2]);
        if (luminance > kMinimumLuminance) {
          const float rolled = std::min(
              1.0F, std::exp2(display_shoulder_log2(std::log2(luminance), knee,
                                                    ceiling)));
          const float scale = rolled / luminance;
          for (float& channel : rgb) channel *= scale;
        }
      }
      const auto fitted = fit_to_unit_cube(rgb);
      result.base_linear.pixels[base] = fitted[0];
      result.base_linear.pixels[base + 1] = fitted[1];
      result.base_linear.pixels[base + 2] = fitted[2];
      peak = std::max(peak, p3_luminance(fitted[0], fitted[1], fitted[2]));
    }
    row_peak[y] = peak;
  });

  // A full-size grid of zeros rather than a single cell: the encoders build a
  // real auxiliary image from this, and an all-zero grid at the usual
  // dimensions costs almost nothing once HEVC-lossless has compressed it while
  // keeping every downstream size relationship the ordinary one.
  const auto dimensions = choose_gain_dimensions(source);
  result.gain_map = FloatImage(dimensions.width, dimensions.height, 1);
  result.metadata.gain_min = {0, 1};
  result.metadata.gain_max = {0, 1};
  result.metadata.gamma = rational_from_float(1.0F);
  result.metadata.base_offset = {0, 1};
  result.metadata.alternate_offset = {0, 1};
  result.metadata.base_headroom = {0, 1};
  result.metadata.alternate_headroom = {0, 1};
  result.exposure_ev = exposure_ev;
  result.headroom_stops = 0.0F;

  auto& stats = result.stats;
  stats.exposure_ev = exposure_ev;
  stats.headroom_stops = 0.0F;
  stats.headroom_linear = 1.0F;
  float rendered_peak = 0.0F;
  for (const float value : row_peak) rendered_peak = std::max(rendered_peak, value);
  stats.rendered_peak = std::max(1.0F, rendered_peak);
  stats.headroom_utilization = 0.0F;
  stats.gain_min_stops = 0.0F;
  stats.gain_max_stops = 0.0F;
  stats.gain_gamma = 1.0F;
  // Neither display-referred renderer applies local weighting, so unity is the
  // honest report rather than a leftover photographic measurement.
  stats.local_weight_mean = 1.0F;
  stats.local_weight_p95 = 1.0F;
  stats.below_knee_relative_difference_max = 0.0F;
  return result;
}

GainMapResult make_display_referred_hdr_gain_map(const FloatImage& source,
                                                 const GainMapOptions& options,
                                                 float input_headroom) {
  if (source.channels != 3) {
    throw std::invalid_argument("gain-map input must be RGB");
  }
  validate_gain_map_options(options);
  if (!(std::isfinite(input_headroom) && input_headroom > 1.0F)) {
    throw std::invalid_argument(
        "a display-referred HDR render needs an input headroom above 1");
  }

  const float exposure_ev = display_referred_exposure_ev(options);
  const float exposure = std::exp2(exposure_ev);
  const float knee_level = knee_linear(options);
  const float knee = std::log2(knee_level);

  // What the input reaches after exposure, and what the output is allowed to
  // reach. Capping here rather than letting the encoder clip is the point: a
  // 5.6-stop PQ input asked for as a 3-stop Adaptive HEIC is remapped by the
  // same shoulder, so its highlights compress deliberately instead of
  // flattening against the format ceiling.
  const float available_stops =
      std::max(0.0F, std::log2(std::max(input_headroom * exposure, 1.0F)));
  const float requested_stops =
      options.auto_headroom
          ? options.look.headroom_max_stops
          : std::clamp(options.headroom_stops, 0.0F,
                       options.look.headroom_max_stops);
  const float output_stops =
      std::max(0.0F, std::min(available_stops, requested_stops) *
                         std::min(options.gain_strength, 1.0F));

  // Both renditions come from one shoulder; only the ceiling differs, so below
  // the knee they are the same function and the gain there is zero. Each
  // ceiling is solved so the input's declared peak lands exactly on its target:
  // 1.0 for the base, `output_stops` for the rendition.
  // An input whose declared headroom the exposure has already brought back to
  // diffuse white has nothing to split, and the solve below would be asked for
  // a target it is already standing on.
  const bool nothing_to_split = available_stops <= kEpsilon;
  const float sdr_ceiling =
      nothing_to_split ? 0.0F : ceiling_for_target(knee, available_stops, 0.0F);
  const auto sdr_of = [&](const float luminance) {
    if (!(luminance > kMinimumLuminance)) return luminance;
    if (nothing_to_split) return std::min(1.0F, luminance);
    return std::min(
        1.0F,
        std::exp2(display_shoulder_log2(std::log2(luminance), knee, sdr_ceiling)));
  };
  // When the output can hold everything the input declared, the rendition is
  // the input. Compressing it anyway is what made a faithful re-export
  // impossible, and there is nothing to gain from rolling off range that fits.
  const bool passes_through =
      nothing_to_split || output_stops >= available_stops - kEpsilon;
  const float hdr_ceiling =
      passes_through ? 0.0F : ceiling_for_target(knee, available_stops, output_stops);
  const auto hdr_of = [&](const float luminance) {
    if (!(luminance > kMinimumLuminance)) return luminance;
    if (passes_through) return luminance;
    return std::exp2(
        display_shoulder_log2(std::log2(luminance), knee, hdr_ceiling));
  };
  // The gain one pixel asks for, already capped at the output budget and
  // suppressed below the knee. Suppression is per pixel here rather than per
  // cell, so a shadow beside a highlight contributes nothing to its cell.
  const auto pixel_gain = [&](const float luminance) {
    if (!(luminance > kMinimumLuminance)) return 0.0F;
    const float sdr = sdr_of(luminance);
    // The display-referred contract is exact below the knee: the base and
    // alternate rendition are the same function there. Before gain-map
    // dithering, the tiny values produced by the transition were merely
    // rounded away; make the invariant explicit so dithering cannot turn
    // them into a visible one-code gain.
    if (sdr <= knee_level) return 0.0F;
    const float gain =
        std::max(0.0F, std::log2((hdr_of(luminance) + kEpsilon) / (sdr + kEpsilon)));
    return std::min(gain, output_stops) *
           smoothstep(knee_level * 0.45F, knee_level * 1.05F, sdr);
  };

  const auto cells = measure_cell_gains(source, exposure, pixel_gain);
  const auto& dimensions = cells.dimensions;

  auto quantized = quantize_grid(cells.stops, dimensions);

  GainMapResult result;
  result.gain_map = std::move(quantized.codes);
  result.base_linear = FloatImage(source.width, source.height, 3);

  const GridView gain_view(result.gain_map.pixels, dimensions.width,
                           dimensions.height);
  const BilinearGridSampler sampler(dimensions.width, dimensions.height,
                                    source.width, source.height);
  const float stored_gain_max = quantized.stored_gain_max;
  const float stored_gamma = quantized.stored_gamma;

  std::vector<float> row_peak(source.height, 0.0F);
  std::vector<float> row_below(source.height, 0.0F);
  parallel_for_rows(source.height, [&](const std::uint32_t y) {
    float peak = 0.0F;
    float below = 0.0F;
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const std::size_t base =
          (static_cast<std::size_t>(y) * source.width + x) * 3;
      const std::array<float, 3> input{
          positive_finite(source.pixels[base]) * exposure,
          positive_finite(source.pixels[base + 1]) * exposure,
          positive_finite(source.pixels[base + 2]) * exposure};
      const float luminance = p3_luminance(input[0], input[1], input[2]);
      const float sdr_luminance = sdr_of(luminance);
      // Chroma rides the luminance change, so a pixel the shoulder leaves alone
      // reaches the base unchanged.
      const float scale =
          luminance > kMinimumLuminance ? sdr_luminance / luminance : 1.0F;
      const auto fitted = fit_to_unit_cube(
          {input[0] * scale, input[1] * scale, input[2] * scale});
      result.base_linear.pixels[base] = fitted[0];
      result.base_linear.pixels[base + 1] = fitted[1];
      result.base_linear.pixels[base + 2] = fitted[2];

      const float local_gain =
          stored_gain_max *
          decode_gain_code(sampler.sample(gain_view, x, y),
                           stored_gamma);
      const float sdr = p3_luminance(fitted[0], fitted[1], fitted[2]);
      const float reconstructed = sdr * std::exp2(local_gain);
      peak = std::max(peak, reconstructed);
      if (luminance <= knee_level) {
        below = std::max(below,
                         std::abs(reconstructed - sdr) / std::max(sdr, kEpsilon));
      }
    }
    row_peak[y] = peak;
    row_below[y] = below;
  });

  result.metadata.gain_min = {0, 1};
  result.metadata.gain_max = quantized.gain_max_metadata;
  result.metadata.gamma = quantized.gamma_metadata;
  result.metadata.base_offset = {0, 1};
  result.metadata.alternate_offset = {0, 1};
  result.metadata.base_headroom = {0, 1};
  // Same single-channel Apple-compatible profile the photographic writer emits.
  result.metadata.alternate_headroom = quantized.gain_max_metadata;
  result.exposure_ev = exposure_ev;
  result.headroom_stops = stored_gain_max;

  auto& stats = result.stats;
  stats.exposure_ev = exposure_ev;
  stats.headroom_stops = output_stops;
  stats.headroom_linear = std::exp2(output_stops);
  float rendered_peak = 1.0F;
  float below_knee = 0.0F;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    rendered_peak = std::max(rendered_peak, row_peak[y]);
    below_knee = std::max(below_knee, row_below[y]);
  }
  stats.rendered_peak = rendered_peak;
  stats.headroom_utilization =
      stats.headroom_linear > 1.0F
          ? std::clamp((rendered_peak - 1.0F) / (stats.headroom_linear - 1.0F),
                       0.0F, 1.0F)
          : 0.0F;
  stats.below_knee_relative_difference_max = below_knee;
  stats.gain_min_stops = 0.0F;
  stats.gain_max_stops = stored_gain_max;
  stats.gain_gamma = stored_gamma;
  stats.local_weight_mean = 1.0F;
  stats.local_weight_p95 = 1.0F;
  measure_quantized_gain(stats, result.gain_map, stored_gain_max, stored_gamma, output_stops);
  return result;
}

}  // namespace hyperdr

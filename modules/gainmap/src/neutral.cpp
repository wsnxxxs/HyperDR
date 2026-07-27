#include "hyperdr/gainmap/gain_map.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace hyperdr {
namespace {

// The neutral renderer's own guard band: 1/64 matches the base and alternate
// offsets this renderer writes into its metadata, and reconstruction only
// round-trips if the three agree.
constexpr float kNeutralOffset = 1.0F / 64.0F;

}  // namespace

// The earlier renderer, kept unchanged as a comparison and rollback path: a
// fixed 0.75 knee on luminance, a per-pixel gain against a percentile-trimmed
// coding range, and 2x2 averaging into the gain map.
GainMapResult make_neutral_gain_map(const FloatImage& source,
                                    const GainMapOptions& options) {
  if (source.channels != 3) throw std::invalid_argument("gain-map input must be RGB");
  std::vector<float> sampled_luminance;
  const std::size_t pixel_count = static_cast<std::size_t>(source.width) * source.height;
  const std::size_t step = std::max<std::size_t>(1, pixel_count / 200000);
  sampled_luminance.reserve(pixel_count / step + 1);
  double log_sum = 0.0;
  std::size_t log_count = 0;
  for (std::size_t i = 0; i < pixel_count; i += step) {
    const auto base = i * 3;
    const float y = p3_luminance(source.pixels[base], source.pixels[base + 1], source.pixels[base + 2]);
    if (std::isfinite(y)) {
      sampled_luminance.push_back(y);
      log_sum += std::log(std::max(y, 1.0e-6F));
      ++log_count;
    }
  }
  const float log_average = log_count == 0 ? 0.18F : static_cast<float>(std::exp(log_sum / log_count));
  const float selected_exposure_ev = options.auto_exposure
      ? clamp_finite(std::log2(0.18F / std::max(log_average, 1.0e-6F)), -6.0F, 6.0F)
      : clamp_finite(options.exposure_ev, -10.0F, 10.0F);
  const float exposure_ev =
      clamp_finite(selected_exposure_ev + options.exposure_bias_ev, -10.0F, 10.0F);
  const float exposure = std::exp2(exposure_ev);

  float headroom_stops = options.headroom_stops;
  if (options.auto_headroom) {
    const float highlight = percentile(sampled_luminance, 0.999F) * exposure;
    headroom_stops = std::log2(std::max(1.0F, highlight));
  }
  headroom_stops = clamp_finite(headroom_stops, 0.0F, kNeutralHeadroomStops);
  const float headroom = std::exp2(headroom_stops);

  GainMapResult result;
  result.base_linear = FloatImage(source.width, source.height, 3);
  const auto gain_width = (source.width + 1) / 2;
  const auto gain_height = (source.height + 1) / 2;
  result.gain_map = FloatImage(gain_width, gain_height, 1);
  result.exposure_ev = exposure_ev;
  result.headroom_stops = headroom_stops;

  // SDR base: identity below the knee so midtones match the HDR rendition exactly,
  // with a smooth C1-continuous shoulder that compresses highlights into [knee, 1).
  // The knee is shared with the curve export, which has to describe this
  // renderer rather than the photographic one.
  constexpr float kKnee = kNeutralKnee;
  const auto sample_count = pixel_count / step + (pixel_count % step ? 1 : 0);
  std::vector<float> gain_sample(sample_count);
  auto& gain_pixels = result.gain_map.pixels;
  parallel_for_rows(gain_height, [&](const std::uint32_t gain_y) {
    const auto source_y_begin = static_cast<std::size_t>(gain_y) * 2;
    const auto source_y_end = std::min<std::size_t>(source.height, source_y_begin + 2);
    for (std::size_t source_y = source_y_begin; source_y < source_y_end; ++source_y) {
      for (std::size_t source_x = 0; source_x < source.width; ++source_x) {
        const auto i = source_y * source.width + source_x;
        const auto p = i * 3;
        float hdr[3]{};
        for (unsigned c = 0; c < 3; ++c) hdr[c] = std::max(0.0F, source.pixels[p + c] * exposure);
        const float hdr_y = p3_luminance(hdr[0], hdr[1], hdr[2]);
        float base_y = hdr_y;
        if (hdr_y > kKnee) {
          const float u = (hdr_y - kKnee) / (1.0F - kKnee);
          base_y = kKnee + (1.0F - kKnee) * u / (1.0F + u);
        }
        const float luminance_scale = hdr_y > 1.0e-8F ? base_y / hdr_y : 1.0F;
        const float max_component = std::max({hdr[0], hdr[1], hdr[2]});
        const float gamut_scale = max_component > 1.0F ? 1.0F / max_component : 1.0F;
        // A single-channel gain map can only restore a common RGB scale. Never clip
        // individual base channels: doing so changes chromaticity and the gain map
        // then magnifies that hue error in HDR highlights.
        const float base_scale = std::min(luminance_scale, gamut_scale);
        for (unsigned c = 0; c < 3; ++c) {
          result.base_linear.pixels[p + c] = clamp_finite(hdr[c] * base_scale, 0.0F, 1.0F);
        }
        const float alt_y = std::min(hdr_y, headroom);
        const float actual_base_y = hdr_y * base_scale;
        const float log_gain = std::log2((alt_y + kNeutralOffset) / (actual_base_y + kNeutralOffset));
        // gain_strength scales the stored log ratio exactly once; decoding applies
        // lerp(gain_min, gain_max, encoded), so the metadata below uses the same scale.
        const float full_gain = clamp_finite(log_gain * options.gain_strength, -16.0F, 16.0F);
        gain_pixels[gain_y * gain_width + source_x / 2] += full_gain;
        if (i % step == 0) gain_sample[i / step] = full_gain;
      }
    }
  });

  // Robust range from sampled percentiles (0.1% outlier trim on each side, like
  // libavif/libultrahdr) so a few hot pixels do not waste 8-bit code values.
  float gain_min = std::min(0.0F, percentile(gain_sample, 0.001F));
  float gain_max = std::max(gain_min, percentile(gain_sample, 0.999F));
  const float gain_range = gain_max - gain_min;

  for (std::uint32_t y = 0; y < gain_height; ++y) {
    for (std::uint32_t x = 0; x < gain_width; ++x) {
      const auto source_x = static_cast<std::size_t>(x) * 2;
      const auto source_y = static_cast<std::size_t>(y) * 2;
      const auto x_count = std::min<std::size_t>(2, source.width - source_x);
      const auto y_count = std::min<std::size_t>(2, source.height - source_y);
      const float average = gain_pixels[static_cast<std::size_t>(y) * gain_width + x] /
                            static_cast<float>(x_count * y_count);
      result.gain_map.at(x, y, 0) =
          gain_range > 1.0e-6F ? std::clamp((average - gain_min) / gain_range, 0.0F, 1.0F) : 0.0F;
    }
  }

  result.metadata.gain_min = rational_from_float(gain_min);
  result.metadata.gain_max = rational_from_float(gain_max);
  result.metadata.gamma = {1, 1};
  result.metadata.base_offset = {1, 64};
  result.metadata.alternate_offset = {1, 64};
  result.metadata.base_headroom = {0, 1};

  // Headroom has to describe the rendition a decoder can actually rebuild from
  // the base image and the gain map that was encoded -- not the peak this
  // renderer saw before the percentile trim, the 2x2 averaging and the 8-bit
  // quantization each took part of it away.
  //
  // The case that made this concrete: 9,999 pixels at 0.1 and one at 100. The
  // 99.9th-percentile trim discards that single sample, gain_max collapses to
  // gain_min, every stored code is zero -- and the metadata still announced
  // about three stops of highlight that nothing in the file could reconstruct.
  //
  // The estimate reads back the values that will be written: the rationalised
  // gain_min/gain_max a decoder will parse, and the 8-bit code the encoder will
  // store. It samples each gain cell against the brightest base pixel under it,
  // which is the same 2x2 grouping the map was built from.
  const float stored_gain_min = rational_value(result.metadata.gain_min);
  const float stored_gain_max = rational_value(result.metadata.gain_max);
  std::vector<float> row_alternate(gain_height, 1.0F);
  parallel_for_rows(gain_height, [&](const std::uint32_t gain_y) {
    float alternate_max = 1.0F;
    const auto source_y_begin = static_cast<std::size_t>(gain_y) * 2;
    const auto source_y_end = std::min<std::size_t>(source.height, source_y_begin + 2);
    for (std::uint32_t gain_x = 0; gain_x < gain_width; ++gain_x) {
      const float code =
          std::round(255.0F * result.gain_map.at(gain_x, gain_y, 0)) / 255.0F;
      const float decoded_gain =
          stored_gain_min + code * (stored_gain_max - stored_gain_min);
      const float expansion = std::exp2(decoded_gain);
      const auto source_x_begin = static_cast<std::size_t>(gain_x) * 2;
      const auto source_x_end =
          std::min<std::size_t>(source.width, source_x_begin + 2);
      for (std::size_t source_y = source_y_begin; source_y < source_y_end; ++source_y) {
        for (std::size_t source_x = source_x_begin; source_x < source_x_end; ++source_x) {
          const auto p = (source_y * source.width + source_x) * 3;
          const float base_y = p3_luminance(result.base_linear.pixels[p],
                                            result.base_linear.pixels[p + 1],
                                            result.base_linear.pixels[p + 2]);
          const float reconstructed =
              (base_y + kNeutralOffset) * expansion - kNeutralOffset;
          alternate_max = std::max(alternate_max, reconstructed);
        }
      }
    }
    row_alternate[gain_y] = alternate_max;
  });
  const float encoded_peak =
      *std::max_element(row_alternate.begin(), row_alternate.end());
  result.headroom_stops = std::log2(std::max(encoded_peak, 1.0F));
  result.metadata.alternate_headroom = rational_from_float(result.headroom_stops);
  result.stats.headroom_stops = headroom_stops;
  result.stats.headroom_linear = headroom;
  result.stats.rendered_peak = std::max(encoded_peak, 1.0F);
  result.stats.headroom_utilization =
      headroom > 1.0F ? std::clamp(std::log2(std::max(encoded_peak, 1.0F)) /
                                       headroom_stops,
                                   0.0F, 1.0F)
                      : 0.0F;
  result.stats.gain_min_stops = stored_gain_min;
  result.stats.gain_max_stops = stored_gain_max;
  return result;
}

}  // namespace hyperdr

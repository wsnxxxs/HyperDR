#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/color.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>
namespace hyperdr {
PhotoRenditions renditions_from_gain_map(GainMapResult images, bool include_hdr) {
  PhotoRenditions out;
  if(include_hdr) out.hdr=reconstruct_gain_map(images.base_linear, images.gain_map,
      images.metadata, images.headroom_stops, nullptr, images.clamp_srgb);
  out.sdr=std::move(images.base_linear); out.stats=images.stats;
  out.clamp_srgb=images.clamp_srgb;
  if(!include_hdr) {out.stats.headroom_stops=0;out.stats.headroom_linear=1;}
  measure_rendition_stats(out.stats,out.sdr,out.hdr);
  return out;
}
PhotoRenditions render_graded_gain_map(GainMapResult& images,
    const ColorLutOptions& grade, bool include_hdr, const ColorLut* lut) {
  if (!grade.path.empty() && grade.strength>0) {
    PhotoRenditions base;
    base.sdr=std::move(images.base_linear);
    base.clamp_srgb=images.clamp_srgb;
    apply_rendition_lut(base,grade,lut);
    images.base_linear=std::move(base.sdr);
  }
  auto out=renditions_from_gain_map(images,include_hdr);
  if (include_hdr) images.stats=out.stats;
  return out;
}
namespace {

// Pulls a colour into the unit cube at its own luminance and Oklab hue, giving
// up only chroma that has nowhere to go.
std::array<float, 3> fit_unit_cube(std::array<float, 3> rgb) {
  return fit_linear_p3_gamut(rgb[0], rgb[1], rgb[2], 1.0F);
}

// Packages an HDR rendition that has to decode back to itself.
// This export path derives the base from decoded per-pixel gain instead of
// averaging gain into cells.
//
// A display-referred HDR input is the photograph, not an expansion the renderer
// chose, so a coarse map cannot be used for it: averaging gain over a cell
// gives a bright pixel its darker neighbours' gain, and a Sony HLG
// frame came back with its highlights about a fifth darker, while a
// single-channel map that multiplies the *SDR* rendition could only return that
// rendition's desaturated chroma. Here every pixel gets its own gain and the
// base is derived from the HDR pixel, so `base x 2^gain` is the HDR pixel
// again. Full resolution is also what keeps that true in every decoder: at 1:1
// there is no resampling, whereas Core Image and this project each
// interpolate a smaller map by a different rule.
//
// Per pixel the gain is the larger of the tone map's luminance ratio (so the
// base keeps the SDR rendition's brightness) and the ratio that brings the
// brightest channel down to 1.0 (so the base keeps the HDR chroma rather than
// being gamut-fitted), capped at the rendition's headroom. The cap keeps the
// declared alternate headroom at the photograph's real luminance range: raising
// it for a few saturated lights would make every display with less headroom
// scale down all highlights. Colours beyond that volume -- a channel brighter
// than the headroom -- keep their luminance and lose only the excess chroma.
//
// Codes are rounded up and the base is then computed from the *decoded* gain,
// so the 8-bit gain step is absorbed by the base (at most one step, 0.6%, of
// SDR brightness at 2.3 stops) instead of reappearing as HDR banding.
GainMapResult exact_gain_map_from_renditions(PhotoRenditions images) {
  auto& base = images.sdr;
  const auto& hdr = images.hdr;
  const std::uint32_t width = hdr.width, height = hdr.height;
  const float cap = std::max(0.0F, images.stats.headroom_stops);

  FloatImage stops(width, height, 1);
  std::vector<float> row_max(height, 0.0F);
  parallel_for_rows(height, [&](std::uint32_t y) {
    float maximum = 0.0F;
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * width + x) * 3;
      const float r = std::max(0.0F, hdr.pixels[i]);
      const float g = std::max(0.0F, hdr.pixels[i + 1]);
      const float b = std::max(0.0F, hdr.pixels[i + 2]);
      const float peak = std::max({r, g, b});
      float value = 0.0F;
      if (peak > 1.0e-9F && std::isfinite(peak)) {
        const float luminance = p3_luminance(r, g, b);
        const float target = p3_luminance(base.pixels[i], base.pixels[i + 1], base.pixels[i + 2]);
        const float tone = luminance > 1.0e-9F && target > 1.0e-9F
            ? std::log2(luminance / target) : 0.0F;
        value = std::clamp(std::max(tone, std::log2(peak)), 0.0F, cap);
      }
      stops.pixels[static_cast<std::size_t>(y) * width + x] = value;
      maximum = std::max(maximum, value);
    }
    row_max[y] = maximum;
  });
  const float requested_max = *std::max_element(row_max.begin(), row_max.end());

  GainMapResult out;
  out.metadata.gain_min = {0, 1};
  out.metadata.gain_max = rational_from_float(requested_max);
  out.metadata.gamma = {1, 1};
  out.metadata.base_offset = {0, 1};
  out.metadata.alternate_offset = {0, 1};
  out.metadata.base_headroom = {0, 1};
  out.metadata.alternate_headroom = out.metadata.gain_max;
  const float stored_max = rational_value(out.metadata.gain_max);

  std::vector<float> row_peak(height, 1.0F), row_below(height, 0.0F);
  parallel_for_rows(height, [&](std::uint32_t y) {
    float peak = 1.0F, below = 0.0F;
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * width + x;
      const auto i = pixel * 3;
      float code = 0.0F;
      if (stored_max > kEpsilon) {
        // One code of slack is subtracted before rounding up so a value that
        // lands on a code boundary through float noise is not pushed a full
        // step higher than it needs.
        code = std::clamp(std::ceil(stops.pixels[pixel] / stored_max * 255.0F - 1.0e-3F),
                          0.0F, 255.0F);
      }
      stops.pixels[pixel] = code / 255.0F;
      const float decoded = stored_max * code / 255.0F;
      const float scale = std::exp2(-decoded);
      const auto fitted = fit_unit_cube({std::max(0.0F, hdr.pixels[i]) * scale,
                                         std::max(0.0F, hdr.pixels[i + 1]) * scale,
                                         std::max(0.0F, hdr.pixels[i + 2]) * scale});
      for (unsigned c = 0; c < 3; ++c) base.pixels[i + c] = fitted[c];
      const float sdr_y = p3_luminance(fitted[0], fitted[1], fitted[2]);
      const float hdr_y = sdr_y * std::exp2(decoded);
      peak = std::max(peak, hdr_y);
      if (!images.below_knee.empty() && images.below_knee[pixel]) {
        below = std::max(below, std::abs(hdr_y - sdr_y) / std::max(sdr_y, kEpsilon));
      }
    }
    row_peak[y] = peak;
    row_below[y] = below;
  });

  out.gain_map = std::move(stops);
  out.base_linear = std::move(base);
  out.clamp_srgb = images.clamp_srgb;
  out.exposure_ev = images.stats.exposure_ev;
  out.headroom_stops = stored_max;
  out.stats = images.stats;
  auto& stats = out.stats;
  stats.gain_min_stops = 0.0F;
  stats.gain_max_stops = stored_max;
  stats.gain_gamma = 1.0F;
  measure_quantized_gain(stats, out.gain_map, stored_max, 1.0F, cap);
  stats.rendered_peak = *std::max_element(row_peak.begin(), row_peak.end());
  stats.headroom_utilization = stats.headroom_linear > 1.0F
      ? std::clamp((stats.rendered_peak - 1.0F) / (stats.headroom_linear - 1.0F), 0.0F, 1.0F)
      : 0.0F;
  stats.below_knee_relative_difference_max =
      *std::max_element(row_below.begin(), row_below.end());
  return out;
}

// ISO 21496-1 weights the gain by (H - BaseHeadroom) / (AlternateHeadroom -
// BaseHeadroom), so a file must declare AlternateHeadroom above BaseHeadroom
// even when it carries no HDR; a distinct alternate headroom avoids ambiguous gain weighting.
// A rendering with no headroom declares this smallest step over a base
// headroom of 0 together with zero gain, so every reader shows its SDR base.
// The step is the smallest that still survives a reader's single-precision
// exp2(): the linear alternate capacity must exceed 1.
constexpr Rational kMinimumAlternateHeadroom{1, 1U << 23};

// The stored form of quantized RGB gain codes, decided by their content so the
// same pair always gives the same bytes. Three channels whose codes differ by
// at most one step anywhere carry no colour of their own: they become one
// channel holding the rounded mean. A map that is one code everywhere (a
// rendering with no headroom) becomes one channel shrunk by the largest of
// 16, 8, 4 and 2 that divides both sides; reconstruction is unchanged.
// One channel needs one set of offsets, so differing offsets keep RGB.
void shrink_gain_codes(FloatImage& codes, const std::array<float, 3>& base_offsets,
                       const std::array<float, 3>& alternate_offsets) {
  const auto width = codes.width, height = codes.height;
  const bool common = base_offsets[0] == base_offsets[1] && base_offsets[0] == base_offsets[2] &&
                      alternate_offsets[0] == alternate_offsets[1] &&
                      alternate_offsets[0] == alternate_offsets[2];
  if (codes.channels == 3 && !common) return;
  const auto step = [&](std::size_t i) { return std::lround(codes.pixels[i] * 255.0F); };
  const auto first = step(0);
  std::vector<std::uint8_t> row_spread(height), row_constant(height);
  parallel_for_rows(height, [&](std::uint32_t y) {
    bool narrow = true, constant = true;
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * width + x) * codes.channels;
      long low = step(i), high = low;
      for (unsigned c = 1; c < codes.channels; ++c) {
        low = std::min(low, step(i + c)); high = std::max(high, step(i + c));
      }
      narrow = narrow && high - low <= 1;
      constant = constant && low == first && high == first;
    }
    row_spread[y] = narrow; row_constant[y] = constant;
  });
  const auto all = [](const std::vector<std::uint8_t>& rows) {
    return std::all_of(rows.begin(), rows.end(), [](std::uint8_t v) { return v != 0; });
  };
  if (all(row_constant)) {
    std::uint32_t factor = 1;
    for (std::uint32_t f : {16U, 8U, 4U, 2U}) {
      if (width % f == 0 && height % f == 0) { factor = f; break; }
    }
    FloatImage shrunk(width / factor, height / factor, 1);
    std::fill(shrunk.pixels.begin(), shrunk.pixels.end(), static_cast<float>(first) / 255.0F);
    codes = std::move(shrunk);
    return;
  }
  if (codes.channels != 3 || !all(row_spread)) return;
  FloatImage mono(width, height, 1);
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * width + x;
      const long sum = step(pixel * 3) + step(pixel * 3 + 1) + step(pixel * 3 + 2);
      mono.pixels[pixel] = static_cast<float>((sum + 1) / 3) / 255.0F;
    }
  });
  codes = std::move(mono);
}

// Preserve both endpoints when grading gives them independent RGB ratios.
// Offsets use the same SDR-white-relative units on encode and reconstruction;
// they keep a LUT's zero-valued channel representable without infinite gain.
// A shared coding range/gamma also fits common XMP + ISO writers.
GainMapResult rgb_gain_map_from_renditions(PhotoRenditions images) {
  constexpr float offset = 1.0F / 64.0F;
  const auto width = images.sdr.width, height = images.sdr.height;
  // A rendering without headroom (an explicit --headroom 0) still writes the
  // requested format, honestly: zero gain everywhere, so the HDR rendition is
  // the SDR one, with no correction of anything.
  const bool no_headroom = !(images.stats.headroom_stops > kEpsilon);
  unsigned channels = images.dual_rendition && images.authored_gain_channels == 1 ? 1 : 3;
  std::array<float, 3> base_offsets{offset, offset, offset}, alternate_offsets{offset, offset, offset};
  if (images.dual_rendition &&
      (images.authored_gain_map.base_offset[0] != images.authored_gain_map.base_offset[1] ||
       images.authored_gain_map.base_offset[0] != images.authored_gain_map.base_offset[2] ||
       images.authored_gain_map.alternate_offset[0] != images.authored_gain_map.alternate_offset[1] ||
       images.authored_gain_map.alternate_offset[0] != images.authored_gain_map.alternate_offset[2])) {
    base_offsets = images.authored_gain_map.base_offset;
    alternate_offsets = images.authored_gain_map.alternate_offset;
  }
  const auto offset_rational = [](float value) {
    return value == offset ? Rational{1,64} : rational_from_float(value, 1U << 24);
  };
  FloatImage codes(width, height, channels);
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * width + x;
      for (unsigned c = 0; c < channels; ++c) {
        const auto i = pixel * 3;
        const auto base = channels == 1 ? p3_luminance(images.sdr.pixels[i], images.sdr.pixels[i+1], images.sdr.pixels[i+2]) : images.sdr.pixels[i+c];
        const auto alternate = channels == 1 ? p3_luminance(images.hdr.pixels[i], images.hdr.pixels[i+1], images.hdr.pixels[i+2]) : images.hdr.pixels[i+c];
        const float denominator = std::max(0.0F, base) + base_offsets[c];
        const float numerator = std::max(0.0F, alternate) + alternate_offsets[c];
        codes.pixels[pixel * channels + c] =
            !no_headroom && denominator > 0 && numerator > 0 ? std::log2(numerator / denominator) : 0;
      }
    }
  });
  std::vector<float> row_min(height), row_max(height);
  parallel_for_rows(height, [&](std::uint32_t y) {
    const auto begin = codes.pixels.begin() + static_cast<std::size_t>(y) * width * channels;
    const auto bounds = std::minmax_element(begin, begin + static_cast<std::size_t>(width) * channels);
    row_min[y] = *bounds.first; row_max[y] = *bounds.second;
  });
  const float minimum = *std::min_element(row_min.begin(), row_min.end());
  const float maximum = *std::max_element(row_max.begin(), row_max.end());
  GainMapResult out;
  auto& metadata = out.metadata;
  metadata.gain_min = rational_from_float(std::min(0.0F, minimum));
  metadata.gain_max = rational_from_float(std::max(0.0F, maximum));
  const float min_gain = rational_value(metadata.gain_min);
  const float max_gain = rational_value(metadata.gain_max);
  const float range = max_gain - min_gain;
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::size_t i = static_cast<std::size_t>(y) * width * channels;
         i < static_cast<std::size_t>(y + 1) * width * channels; ++i)
      codes.pixels[i] = range > kEpsilon ? std::clamp((codes.pixels[i] - min_gain) / range, 0.0F, 1.0F) : 0.0F;
  });
  metadata.gamma = rational_from_float(range > kEpsilon ? choose_gain_gamma(codes.pixels) : 1.0F);
  const float gamma = rational_value(metadata.gamma);
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::size_t i = static_cast<std::size_t>(y) * width * channels;
         i < static_cast<std::size_t>(y + 1) * width * channels; ++i)
      codes.pixels[i] = std::round(encode_gain_code(codes.pixels[i], gamma) * 255.0F) / 255.0F;
  });
  if (!images.fixed_gain_channels) shrink_gain_codes(codes, base_offsets, alternate_offsets);
  channels = codes.channels;
  metadata.base_offset = offset_rational(base_offsets[0]);
  metadata.alternate_offset = offset_rational(alternate_offsets[0]);
  metadata.base_headroom = {0, 1};
  // Display capacity is the rendered peak, independent of channel gain extrema.
  metadata.alternate_headroom = no_headroom ? kMinimumAlternateHeadroom
                                            : rational_from_float(images.stats.headroom_stops);
  if (channels == 3) {
    const auto channel = gain_map_channel(metadata, 0);
    metadata.flags |= 0x80;
    metadata.channels.assign(3, channel);
    for (unsigned c = 0; c < 3; ++c) {
      metadata.channels[c].base_offset = offset_rational(base_offsets[c]);
      metadata.channels[c].alternate_offset = offset_rational(alternate_offsets[c]);
    }
  }
  out.headroom_stops = no_headroom ? 0.0F : rational_value(metadata.alternate_headroom);
  out.exposure_ev = images.stats.exposure_ev;
  out.clamp_srgb = images.clamp_srgb;
  out.base_linear = std::move(images.sdr);
  out.gain_map = std::move(codes);
  out.stats = images.stats;
  out.stats.gain_min_stops = min_gain;
  out.stats.gain_max_stops = max_gain;
  out.stats.gain_gamma = gamma;
  measure_quantized_gain(out.stats, out.gain_map, max_gain, gamma, 0.0F, min_gain);
  images.hdr = {};
  const auto reconstructed = reconstruct_gain_map(out.base_linear, out.gain_map,
      metadata, out.headroom_stops, nullptr, out.clamp_srgb);
  measure_rendition_stats(out.stats, out.base_linear, reconstructed, images.below_knee);
  return out;
}

// The single RGB multiplier, in stops, that takes an SDR pixel to its HDR pixel
// under the file's offsets. Luminance is linear in RGB, so for a pair that does
// share one multiplier the luminance ratio is that multiplier exactly, whatever
// the colour. Black, or a zero offset denominator, carries no gain.
float mono_gain_stops(float sdr_y, float hdr_y, float base_offset, float alternate_offset) {
  const float base = std::max(0.0F, sdr_y) + base_offset;
  const float alternate = std::max(0.0F, hdr_y) + alternate_offset;
  if (!(base > 1.0e-12F) || !(alternate > 1.0e-12F)) return 0.0F;
  return std::log2(alternate / base);
}

// Packages an authored monochrome pair for Apple-compatible output, keeping
// every authored SDR pixel that one shared multiplier can take to its HDR
// pixel. That is judged by reconstruction error, not by per-channel ratios: a
// zero channel has no meaningful ratio, and the old ratio test rejected every
// Apple frame containing one. The tolerance -- 0.1% of the pixel's brightest
// HDR channel plus a floor far below one 10-bit code at black -- sits under the
// step of the 8-bit gain code that packaging adds anyway.
//
// A pixel outside it (a resized edge, where SDR and HDR were reduced
// separately, or an edit that gave the endpoints different colours) has only
// its own base rebuilt from its HDR pixel and decoded gain, as the exact HDR
// packager does. The HDR stays exact everywhere and any SDR change is confined
// to those pixels: rejecting the whole frame for a few edges rebuilt every
// saturated colour in a reduced iPhone export.
GainMapResult authored_mono_gain_map(PhotoRenditions images) {
  const auto width = images.sdr.width, height = images.sdr.height;
  FloatImage gains(width, height, 1);
  std::vector<std::uint8_t> rebuild(static_cast<std::size_t>(width) * height, 0);
  const float base_offset = images.authored_gain_map.base_offset[0];
  const float alternate_offset = images.authored_gain_map.alternate_offset[0];
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * width + x;
      const auto* sdr = &images.sdr.pixels[pixel * 3];
      const auto* hdr = &images.hdr.pixels[pixel * 3];
      float gain = mono_gain_stops(p3_luminance(sdr[0], sdr[1], sdr[2]),
          p3_luminance(hdr[0], hdr[1], hdr[2]), base_offset, alternate_offset);
      const float multiplier = std::exp2(gain);
      const float peak = std::max({hdr[0], hdr[1], hdr[2], 0.0F});
      const float tolerance = 1.0e-3F * peak + 1.0e-5F;
      bool fits = true;
      for (int c = 0; c < 3 && fits; ++c) {
        const float rebuilt = std::max(0.0F,
            (std::max(0.0F, sdr[c]) + base_offset) * multiplier - alternate_offset);
        fits = std::abs(rebuilt - std::max(0.0F, hdr[c])) <= tolerance;
      }
      if (!fits) {
        // Leave room for the brightest channel inside a unit base.
        rebuild[pixel] = 1;
        gain = std::max(gain, mono_gain_stops(1.0F, peak, base_offset, alternate_offset));
      }
      gains.pixels[pixel] = gain;
    }
  });
  const auto [minimum, maximum] = std::minmax_element(gains.pixels.begin(), gains.pixels.end());
  GainMapResult out;
  out.metadata.gain_min = rational_from_float(std::min(0.0F, *minimum));
  out.metadata.gain_max = rational_from_float(std::max(0.0F, *maximum));
  out.metadata.gamma = {1,1};
  out.metadata.base_offset = rational_from_float(base_offset);
  out.metadata.alternate_offset = rational_from_float(alternate_offset);
  out.metadata.base_headroom = {0,1};
  out.metadata.alternate_headroom = out.metadata.gain_max;
  const float low = rational_value(out.metadata.gain_min);
  const float high = rational_value(out.metadata.gain_max);
  const float range = high-low;
  auto& base = images.sdr;
  std::vector<float> row_change(height, 0.0F);
  parallel_for_rows(height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * width + x;
      auto& gain = gains.pixels[pixel];
      if (!(range > kEpsilon)) { gain = 0; continue; }
      const float position = std::clamp((gain-low)/range,0.0F,1.0F)*255;
      // A rebuilt base absorbs the code step, so its gain rounds up and the
      // base never has to exceed 1.0; an authored base keeps rounding.
      gain = (rebuild[pixel] ? std::ceil(position - 1.0e-3F) : std::round(position))/255;
      if (!rebuild[pixel]) continue;
      const float scale = std::exp2(-(low + range*gain));
      const auto* hdr = &images.hdr.pixels[pixel * 3];
      for (int c = 0; c < 3; ++c) {
        const float rebuilt = std::clamp((std::max(0.0F, hdr[c]) + alternate_offset) * scale -
            base_offset, 0.0F, 1.0F);
        row_change[y] = std::max(row_change[y], std::abs(rebuilt - base.pixels[pixel*3+c]));
        base.pixels[pixel*3+c] = rebuilt;
      }
    }
  });
  out.base_linear = std::move(base);
  out.gain_map = std::move(gains);
  out.clamp_srgb = images.clamp_srgb;
  out.exposure_ev = images.stats.exposure_ev;
  out.headroom_stops = high;
  out.stats = images.stats;
  out.stats.gain_min_stops = low;
  out.stats.gain_max_stops = high;
  out.stats.gain_gamma = 1;
  // Report a changed SDR colour once any rebuilt pixel moved by a linear code.
  out.stats.adaptive_chroma_loss =
      *std::max_element(row_change.begin(), row_change.end()) > 1.0F/255;
  measure_quantized_gain(out.stats,out.gain_map,high,1,0,low);
  images.hdr = {};
  const auto reconstructed = reconstruct_gain_map(out.base_linear,out.gain_map,
      out.metadata,out.headroom_stops,nullptr,out.clamp_srgb);
  measure_rendition_stats(out.stats,out.base_linear,reconstructed,images.below_knee);
  return out;
}

// One multiplier can serve all three channels only if the offsets agree.
bool common_offsets(const PhotoRenditions& images) {
  const auto& offsets = images.authored_gain_map;
  const float bo = offsets.base_offset[0], ao = offsets.alternate_offset[0];
  for (int c = 1; c < 3; ++c)
    if (std::abs(offsets.base_offset[c]-bo) > 1e-6F ||
        std::abs(offsets.alternate_offset[c]-ao) > 1e-6F) return false;
  return true;
}

}  // namespace

GainMapResult gain_map_from_renditions(PhotoRenditions images, GainMapWriterProfile profile) {
  images.sdr.require_consistent("gain-map SDR rendition");
  images.hdr.require_consistent("gain-map HDR rendition");
  const auto& sdr=images.sdr; const auto& hdr=images.hdr;
  if(sdr.channels!=3 || hdr.channels!=3 || sdr.width!=hdr.width || sdr.height!=hdr.height)
    throw std::invalid_argument("gain-map packaging requires matching SDR and HDR renditions");
  if (images.dual_rendition) {
    if (profile == GainMapWriterProfile::iso_generic)
      return rgb_gain_map_from_renditions(std::move(images));
    if (images.authored_gain_channels == 1 && common_offsets(images))
      return authored_mono_gain_map(std::move(images));
    auto result = exact_gain_map_from_renditions(std::move(images));
    result.stats.adaptive_chroma_loss = true;
    return result;
  }
  if (profile == GainMapWriterProfile::iso_generic) {
    return rgb_gain_map_from_renditions(std::move(images));
  }
  if (images.hdr_is_source) return exact_gain_map_from_renditions(std::move(images));
  // Apple-compatible output has one shared RGB multiplier. Derive it from the
  // final endpoints at full resolution: a second cell average would blur the
  // renderer's already-spatial gain and make bright edges reconstruct darker.
  FloatImage stops(sdr.width,sdr.height,1);
  parallel_for_rows(stops.height,[&](std::uint32_t y) {
    for(std::uint32_t x=0;x<stops.width;++x) {
      const auto i=(static_cast<std::size_t>(y)*sdr.width+x)*3;
      const float base=p3_luminance(sdr.pixels[i],sdr.pixels[i+1],sdr.pixels[i+2]);
      const float alternate=p3_luminance(hdr.pixels[i],hdr.pixels[i+1],hdr.pixels[i+2]);
      if(base>1e-6F) stops.at(x,y,0)=std::clamp(
          std::log2(std::max(alternate,base)/base),0.0F,images.stats.headroom_stops);
    }
  });
  auto quantized=quantize_gain_grid(stops.pixels,stops.width);
  const float maximum=quantized.stored_gain_max;
  const float gamma=quantized.stored_gamma;
  stops.pixels=std::move(quantized.codes);
  GainMapResult out;
  out.base_linear=std::move(images.sdr); out.gain_map=std::move(stops);
  out.metadata.gain_min={0,1}; out.metadata.gain_max=quantized.gain_max_metadata;
  out.metadata.gamma=quantized.gamma_metadata;
  out.metadata.base_offset={0,1}; out.metadata.alternate_offset={0,1};
  out.metadata.base_headroom={0,1}; out.metadata.alternate_headroom=out.metadata.gain_max;
  out.clamp_srgb=images.clamp_srgb; out.exposure_ev=images.stats.exposure_ev;
  out.headroom_stops=maximum; out.stats=images.stats;
  out.stats.gain_max_stops=maximum; out.stats.gain_gamma=gamma;
  measure_quantized_gain(out.stats,out.gain_map,maximum,gamma,images.stats.headroom_stops);
  // Release the requested HDR pixels before allocating the actual quantized,
  // bilinearly reconstructed rendition. Report the latter's peak and spill.
  images.hdr={};
  const auto reconstructed=reconstruct_gain_map(out.base_linear,out.gain_map,
      out.metadata,out.headroom_stops,nullptr,out.clamp_srgb);
  measure_rendition_stats(out.stats,out.base_linear,reconstructed,images.below_knee);
  return out;
}
}  // namespace hyperdr

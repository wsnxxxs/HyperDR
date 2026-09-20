#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"
#include <algorithm>
#include <array>
#include <cmath>
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
//
// A display-referred HDR input is the photograph, not an expansion the renderer
// chose, so the cell-averaged map below cannot be used for it: averaging gain
// over a cell gives a bright pixel its darker neighbours' gain, and a Sony HLG
// frame came back with its highlights about a fifth darker, while a
// single-channel map that multiplies the *SDR* rendition could only return that
// rendition's desaturated chroma. Here every pixel gets its own gain and the
// base is derived from the HDR pixel, so `base x 2^gain` is the HDR pixel
// again. Full resolution is also what keeps that true in every decoder: at 1:1
// there is no resampling, whereas libultrahdr, Core Image and this project each
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

}  // namespace

GainMapResult gain_map_from_renditions(PhotoRenditions images) {
  const auto& sdr=images.sdr; const auto& hdr=images.hdr;
  if(sdr.channels!=3 || hdr.channels!=3 || sdr.width!=hdr.width || sdr.height!=hdr.height)
    throw std::invalid_argument("gain-map packaging requires matching SDR and HDR renditions");
  if (images.hdr_is_source) return exact_gain_map_from_renditions(std::move(images));
  const auto dimensions=choose_gain_dimensions(sdr);
  const bool retained = !images.gain_stops.pixels.empty();
  FloatImage stops = retained ? std::move(images.gain_stops)
      : FloatImage(dimensions.width,dimensions.height,1);
  if (!retained) parallel_for_rows(stops.height,[&](std::uint32_t gy) {
    const auto y0=grid_cell_edge(gy,sdr.height,stops.height), y1=grid_cell_edge(gy+1,sdr.height,stops.height);
    for(std::uint32_t gx=0;gx<stops.width;++gx) {
      const auto x0=grid_cell_edge(gx,sdr.width,stops.width), x1=grid_cell_edge(gx+1,sdr.width,stops.width);
      double sum=0;
      for(auto y=y0;y<y1;++y) for(auto x=x0;x<x1;++x) {
        const auto i=(static_cast<std::size_t>(y)*sdr.width+x)*3;
        const float base=p3_luminance(sdr.pixels[i],sdr.pixels[i+1],sdr.pixels[i+2]);
        const float alternate=p3_luminance(hdr.pixels[i],hdr.pixels[i+1],hdr.pixels[i+2]);
        if(base>1e-6F) sum+=std::clamp(std::log2(std::max(alternate,base)/base),0.0F,images.stats.headroom_stops);
      }
      stops.at(gx,gy,0)=static_cast<float>(sum/((x1-x0)*(y1-y0)));
    }
  });
  const float maximum=*std::max_element(stops.pixels.begin(),stops.pixels.end());
  if(maximum>0) for(auto& c:stops.pixels) c/=maximum;
  const float gamma=maximum>0 ? choose_gain_gamma(stops.pixels) : 1;
  for(std::uint32_t y=0;y<stops.height;++y) for(std::uint32_t x=0;x<stops.width;++x)
    stops.at(x,y,0)=quantize_gain_code_dithered(encode_gain_code(stops.at(x,y,0),gamma),x,y);
  GainMapResult out;
  out.base_linear=std::move(images.sdr); out.gain_map=std::move(stops);
  out.metadata.gain_min={0,1}; out.metadata.gain_max=rational_from_float(maximum);
  out.metadata.gamma=rational_from_float(gamma);
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

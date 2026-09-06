#include "hyperdr/look/rendition.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"
#include "hyperdr/look/local_gain.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace hyperdr {
namespace {
float shoulder(float u, float knee, float ceiling) {
  if (u <= knee) return u;
  // Near unit headroom the ceiling is large and exp(x) is almost 1.
  // expm1 keeps that small difference accurate for identity HDR LUTs.
  return knee - (ceiling - knee) * std::expm1(-(u - knee) / (ceiling - knee));
}
float solve_ceiling(float knee, float peak, float target) {
  float lo = knee + 1e-4F, hi = knee + 1.0F;
  for (int i = 0; i < 60 && shoulder(peak, knee, hi) < target; ++i)
    hi = knee + (hi - knee) * 2;
  for (int i = 0; i < 64; ++i) {
    const float mid = (lo + hi) * 0.5F;
    if (shoulder(peak, knee, mid) < target) lo = mid; else hi = mid;
  }
  return (lo + hi) * 0.5F;
}
float mapped(float y, float knee, float ceiling) {
  return y > 1e-6F ? std::exp2(shoulder(std::log2(y), knee, ceiling)) : y;
}
std::array<float, 3> fit(std::array<float, 3> rgb, float limit) {
  const float y = std::clamp(p3_luminance(rgb[0], rgb[1], rgb[2]), 0.0F, limit);
  float a = 1.0F;
  for (const auto c : rgb) {
    const float d = c - y;
    if (d > 0) a = std::min(a, (limit - y) / d);
    if (d < 0) a = std::min(a, -y / d);
  }
  for (auto& c : rgb) c = std::clamp(y + a * (c - y), 0.0F, limit);
  return rgb;
}
}

void fit_sdr_to_srgb(FloatImage& image) {
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * image.width + x) * 3;
      const auto rgb = compress_linear_p3_to_srgb(
          image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]);
      for (int c = 0; c < 3; ++c) image.pixels[i + c] = rgb[c];
    }
  });
}

void measure_rendition_stats(RenderStats& stats, const FloatImage& sdr,
    const FloatImage& hdr, std::span<const std::uint8_t> below_knee) {
  const bool has_hdr = !hdr.pixels.empty();
  const auto& image = has_hdr ? hdr : sdr;
  std::vector<float> peaks(image.height, 1), differences(image.height, 0);
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto pixel = static_cast<std::size_t>(y) * image.width + x;
      const auto i = pixel * 3;
      const float alternate = p3_luminance(image.pixels[i], image.pixels[i+1], image.pixels[i+2]);
      peaks[y] = std::max(peaks[y], alternate);
      if (has_hdr && !below_knee.empty() && below_knee[pixel]) {
        const float base = p3_luminance(sdr.pixels[i], sdr.pixels[i+1], sdr.pixels[i+2]);
        differences[y] = std::max(differences[y], std::abs(alternate-base)/std::max(base,kEpsilon));
      }
    }
  });
  stats.rendered_peak = *std::max_element(peaks.begin(), peaks.end());
  if (!has_hdr) { stats.headroom_stops=0; stats.headroom_linear=1; }
  stats.headroom_utilization = stats.headroom_linear > 1
      ? std::clamp((stats.rendered_peak-1)/(stats.headroom_linear-1),0.0F,1.0F) : 0;
  if (!below_knee.empty() || !has_hdr)
    stats.below_knee_relative_difference_max = *std::max_element(differences.begin(), differences.end());
}

PhotoRenditions render_renditions(const FloatImage& source,
    const RenderOptions& requested_options, const CaptureMetadata& capture,
    const InputDescription& input, RenderTarget target,
    const PhotographicAnalysis* analysis, GainMapPreparation* preparation) {
  source.require_consistent("photo render");
  if (source.channels != 3) throw std::invalid_argument("photo render requires RGB");
  const auto options=render_options_for_target(requested_options,target);
  validate_render_options(options);
  validate_input_description(input);
  const bool scene = input.domain == InputDomain::kSceneReferred;
  const bool input_hdr = input.domain == InputDomain::kDisplayReferredHdr;
  const bool want_hdr = target == RenderTarget::Hdr;
  GainMapPreparation owned;
  auto& prepared = preparation ? *preparation : owned;
  // The photographic preparation is shared with the legacy renderer, but
  // contains float luminance decisions only, never quantized gain codes.
  if (scene) prepare_photographic_render(source, options, capture, analysis, prepared);
  const float ev = scene ? prepared.exposure_ev : std::clamp(
      (options.auto_exposure ? 0.0F : options.exposure_ev) + options.exposure_bias_ev, -10.0F, 10.0F);
  const float exposure = std::exp2(ev);
  const float requested = options.auto_headroom ? options.look.headroom_max_stops : options.headroom_stops;
  const float strength = std::min(1.0F, options.gain_strength);
  const float available = std::max(0.0F, std::log2(input.headroom * exposure));
  const float stops = !want_hdr ? 0.0F : (scene ? prepared.requested_stops :
      input_hdr ? std::min(available, requested) : requested) * strength;
  const float peak = std::exp2(stops);
  const float knee = std::log2(options.look.shoulder_start);
  const float sdr_ceiling = available > kEpsilon ? solve_ceiling(knee, available, 0) : 0;
  const bool hdr_passthrough = input_hdr && stops >= available - kEpsilon;
  const float hdr_ceiling = input_hdr && !hdr_passthrough && available > kEpsilon
      ? solve_ceiling(knee, available, stops) : 0;
  const auto curve = build_tone_curve(options.look);
  PhotoRenditions out;
  out.sdr = FloatImage(source.width, source.height, 3);
  if (want_hdr) {
    out.hdr = FloatImage(source.width, source.height, 3);
    out.below_knee.resize(static_cast<std::size_t>(source.width)*source.height);
  }
  out.clamp_srgb = options.clamp_srgb;
  std::vector<std::uint64_t> wide(source.height), eligible(source.height);
  std::optional<BilinearGridSampler> scene_sampler;
  std::optional<GridView> local_view, stops_view;
  if (scene) {
    scene_sampler.emplace(prepared.width, prepared.height, source.width, source.height);
    local_view.emplace(prepared.local_average, prepared.width, prepared.height);
    stops_view.emplace(prepared.stops, prepared.width, prepared.height);
  }
  parallel_for_rows(source.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * source.width + x) * 3;
      std::array<float, 3> rgb{finite_or_zero(source.pixels[i]),
          finite_or_zero(source.pixels[i+1]), finite_or_zero(source.pixels[i+2])};
      if (p3_luminance(rgb[0], rgb[1], rgb[2]) >= .02F) {
        ++eligible[y];
        if (is_outside_rec709(rgb[0], rgb[1], rgb[2])) ++wide[y];
      }
      for (auto& c : rgb) c *= exposure;
      const float luma = p3_luminance(rgb[0], rgb[1], rgb[2]);
      if (want_hdr) out.below_knee[i/3] = luma <= (scene ? curve.shoulder_input : options.look.shoulder_start);
      float sdr_y, hdr_y;
      std::array<float, 3> base, hdr;
      if (scene) {
        const float tone = render_tone_curve(luma, 1, curve);
        const float local = scene_sampler->sample(*local_view, x, y);
        const float detail = std::clamp(std::log2((tone + kEpsilon)/(local + kEpsilon)), -1.5F, 1.5F);
        const float mask = smoothstep(.025F, .16F, tone) * (1 - .65F * smoothstep(.78F, 1, tone));
        sdr_y = std::clamp(tone * std::exp2(detail * .14F * options.look.pop * mask), 0.0F, 1.0F);
        const float gain = want_hdr ? scene_sampler->sample(*stops_view, x, y) * strength : 0;
        hdr_y = sdr_y * std::exp2(gain);
        base = render_common_chroma(rgb[0], rgb[1], rgb[2], luma, sdr_y, sdr_y, 1, options.look);
        hdr = base;
        for (auto& c : hdr) c *= std::exp2(gain);
      } else {
        sdr_y = available > kEpsilon ? std::min(1.0F, mapped(luma, knee, sdr_ceiling)) : std::min(1.0F, luma);
        hdr_y = input_hdr ? (hdr_passthrough ? luma : available > kEpsilon ? mapped(luma, knee, hdr_ceiling) : luma) : sdr_y;
        // Finished SDR keeps its chosen tone response. HDR expansion is an
        // explicit creative operation, with no claim to recovering capture data.
        const float scale = luma > kEpsilon ? sdr_y / luma : 0;
        base = fit({rgb[0]*scale, rgb[1]*scale, rgb[2]*scale}, 1);
        const float hdr_scale = luma > kEpsilon ? hdr_y / luma : 0;
        hdr = fit({rgb[0]*hdr_scale, rgb[1]*hdr_scale, rgb[2]*hdr_scale}, peak);
      }
      if (options.clamp_srgb) {
        base = compress_linear_p3_to_srgb(base[0], base[1], base[2]);
        hdr = compress_linear_p3_to_srgb(hdr[0], hdr[1], hdr[2], true);
      }
      for (int c = 0; c < 3; ++c) {
        out.sdr.pixels[i+c] = base[c];
        if (want_hdr) out.hdr.pixels[i+c] = hdr[c];
      }
    }
  });
  // SDR expansion retains the existing spatial highlight/noise weighting.
  // SDR-only returns its developed base without allocating or analysing gain.
  if (!scene && !input_hdr && want_hdr && stops > 0) {
    if (!prepared.ready) {
      const auto dims=choose_gain_dimensions(out.sdr);
      std::vector<float> gains(static_cast<std::size_t>(dims.width)*dims.height), guide(gains.size());
      parallel_for_rows(dims.height,[&](std::uint32_t gy) {
        const auto y0=grid_cell_edge(gy,source.height,dims.height), y1=grid_cell_edge(gy+1,source.height,dims.height);
        for(std::uint32_t gx=0;gx<dims.width;++gx) {
          const auto x0=grid_cell_edge(gx,source.width,dims.width), x1=grid_cell_edge(gx+1,source.width,dims.width);
          double sum=0, g=0;
          for(auto y=y0;y<y1;++y) for(auto x=x0;x<x1;++x) {
            const float l=p3_luminance(out.sdr.at(x,y,0),out.sdr.at(x,y,1),out.sdr.at(x,y,2));
            sum+=l; g+=requested*smoothstep(options.look.shoulder_start,1,l);
          }
          const auto i=static_cast<std::size_t>(gy)*dims.width+gx;
          const auto count=(x1-x0)*(y1-y0);
          guide[i]=static_cast<float>(sum/count); gains[i]=static_cast<float>(g/count);
        }
      });
      auto local=weight_local_highlights(gains,guide,guide,dims,capture,options.look);
      prepared.width=dims.width; prepared.height=dims.height;
      prepared.stops=std::move(local.stops); prepared.weight_mean=local.weight_mean;
      prepared.weight_p95=local.weight_p95; prepared.ready=true;
    }
    const BilinearGridSampler sampler(prepared.width,prepared.height,source.width,source.height);
    const GridView view(prepared.stops,prepared.width,prepared.height);
    parallel_for_rows(source.height,[&](std::uint32_t y) {
      for(std::uint32_t x=0;x<source.width;++x) {
        const auto i=(static_cast<std::size_t>(y)*source.width+x)*3;
        const float scale=std::exp2(sampler.sample(view,x,y)*strength);
        for(int c=0;c<3;++c) out.hdr.pixels[i+c]=out.sdr.pixels[i+c]*scale;
      }
    });
  }
  if (want_hdr && !input_hdr && prepared.ready) {
    out.gain_stops = FloatImage(prepared.width, prepared.height, 1);
    for (std::size_t i=0; i<prepared.stops.size(); ++i)
      out.gain_stops.pixels[i] = prepared.stops[i] * strength;
  }
  auto& stats = out.stats;
  stats.exposure_ev = ev;
  stats.ev100 = estimate_ev100(capture);
  stats.target_middle_gray = compute_target_middle_gray(stats.ev100);
  stats.headroom_stops = stops; stats.headroom_linear = peak;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    stats.wide_gamut_pixels += wide[y]; stats.wide_gamut_eligible_pixels += eligible[y];
  }
  if (stats.wide_gamut_eligible_pixels) stats.wide_gamut_fraction =
      static_cast<float>(static_cast<double>(stats.wide_gamut_pixels)/stats.wide_gamut_eligible_pixels);
  if (prepared.ready) { stats.local_weight_mean = prepared.weight_mean; stats.local_weight_p95 = prepared.weight_p95; }
  measure_rendition_stats(stats, out.sdr, out.hdr, out.below_knee);
  return out;
}
}  // namespace hyperdr

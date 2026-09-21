#include "hyperdr/look/dcp_render.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/rendition.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {
using RGB = std::array<double, 3>;
using Matrix = std::array<RGB, 3>;
// ProPhoto primaries, D50 (0.3457, 0.3585), with Bradford D65 adaptation.
// LibRaw's D65 ProPhoto helper describes a different space.
constexpr Matrix to_pro{{{0.631691220187, 0.213928184843, 0.154380594970},
    {0.083204316859, 0.885857509646, 0.030938173495},
    {-0.001272734565, 0.050755104337, 0.950517630228}}};
constexpr Matrix to_p3{{{1.632564475640, -0.379768609138, -0.252795866503},
    {-0.153701875180, 1.166713085630, -0.013011210451},
    {0.010393259036, -0.062807871342, 1.052414612306}}};
RGB transform(const Matrix& m, const RGB& v) {
  RGB out{};
  for (int i = 0; i < 3; ++i)
    for (int j = 0; j < 3; ++j) out[i] += m[i][j] * v[j];
  return out;
}
double pin(double x) { return std::clamp(x, 0.0, 1.0); }
double encode(double x) { return x <= 0.0031308 ? 12.92*x : 1.055*std::pow(x, 1.0/2.4)-0.055; }
double decode(double x) { return x <= 0.04045 ? x/12.92 : std::pow((x+0.055)/1.055, 2.4); }
RGB hsv(const RGB& rgb) {
  const double hi = std::max({rgb[0], rgb[1], rgb[2]});
  const double lo = std::min({rgb[0], rgb[1], rgb[2]});
  const double d = hi-lo;
  double h = 0;
  if (d > 0) {
    if (hi == rgb[0]) h = (rgb[1]-rgb[2])/d;
    else if (hi == rgb[1]) h = 2+(rgb[2]-rgb[0])/d;
    else h = 4+(rgb[0]-rgb[1])/d;
    if (h < 0) h += 6;
  }
  return {h, hi > 0 ? d/hi : 0, hi};
}
RGB from_hsv(RGB v) {
  v[0] -= 6*std::floor(v[0]/6);
  const int sector = static_cast<int>(v[0]);
  const double f = v[0]-sector, p = v[2]*(1-v[1]);
  const double q = v[2]*(1-v[1]*f), t = v[2]*(1-v[1]*(1-f));
  switch (sector) {
    case 0: return {v[2],t,p}; case 1: return {q,v[2],p};
    case 2: return {p,v[2],t}; case 3: return {p,q,v[2]};
    case 4: return {t,p,v[2]}; default: return {v[2],p,q};
  }
}
// DCP table storage has saturation varying fastest, then hue, then value.
RGB sample(const DcpHueSatMap& map, const RGB& v) {
  const auto nh=map.dims[0], ns=map.dims[1], nv=map.dims[2];
  const double h=v[0]*nh/6, s=pin(v[1])*(ns-1);
  const double value=(map.srgb_encoding && nv>1 ? encode(pin(v[2])) : pin(v[2]))*(nv-1);
  const auto h0=static_cast<unsigned>(h)%nh, h1=(h0+1)%nh;
  const auto s0=std::min(static_cast<unsigned>(s),ns-2);
  const auto v0=nv>1 ? std::min(static_cast<unsigned>(value),nv-2) : 0;
  const double hf=h-std::floor(h), sf=s-s0, vf=nv>1 ? value-v0 : 0;
  RGB result{};
  for (unsigned z=0; z<(nv>1 ? 2U : 1U); ++z)
    for (unsigned y=0; y<2; ++y)
      for (unsigned x=0; x<2; ++x) {
        const auto index=((v0+z)*nh+(x ? h1:h0))*ns+s0+y;
        const double weight=(x?hf:1-hf)*(y?sf:1-sf)*(nv>1?(z?vf:1-vf):1);
        for (int c=0;c<3;++c) result[c]+=weight*map.values[index][c];
      }
  return result;
}
RGB apply_delta(RGB v, const RGB& delta, bool encoded) {
  v[0]+=delta[0]/60;
  v[1]=pin(v[1]*delta[1]);
  v[2]=pin((encoded ? encode(pin(v[2])) : v[2])*delta[2]);
  if (encoded) v[2]=decode(v[2]);
  return from_hsv(v);
}
RGB apply_map(const RGB& rgb, const DcpHueSatMap& map) {
  if (map.values.empty()) return rgb;
  const auto v=hsv(rgb);
  return apply_delta(v,sample(map,v),map.srgb_encoding && map.dims[2]>1);
}

// Natural cubic spline: the DNG SDK's C2 curve with zero endpoint curvature.
class Tone {
 public:
  explicit Tone(const std::vector<std::array<double,2>>& points) : points_(points) {
    if (points_.empty()) return;
    const auto n=points_.size();
    second_.assign(n,0);
    std::vector<double> upper(n,0), rhs(n,0);
    for (std::size_t i=1;i+1<n;++i) {
      const double a=points_[i][0]-points_[i-1][0];
      const double b=points_[i+1][0]-points_[i][0];
      const double diagonal=2*(a+b)-a*upper[i-1];
      upper[i]=b/diagonal;
      rhs[i]=(6*((points_[i+1][1]-points_[i][1])/b-
          (points_[i][1]-points_[i-1][1])/a)-a*rhs[i-1])/diagonal;
    }
    for (std::size_t i=n-1;i-->0;) second_[i]=rhs[i]-upper[i]*second_[i+1];
  }
  double operator()(double x) const;
 private:
  const std::vector<std::array<double,2>>& points_;
  std::vector<double> second_;
};
#include "dcp_acr3_curve.inc"
double Tone::operator()(double x) const {
  x=pin(x);
  if (points_.empty()) {
    const double position=x*(std::size(kAcr3Curve)-1);
    const auto i=std::min(static_cast<std::size_t>(position),std::size(kAcr3Curve)-2);
    return std::lerp(double(kAcr3Curve[i]),double(kAcr3Curve[i+1]),position-i);
  }
  if (x<=points_.front()[0]) return points_.front()[1];
  if (x>=points_.back()[0]) return points_.back()[1];
  const auto it=std::upper_bound(points_.begin(),points_.end(),x,
      [](double v,const auto& p){return v<p[0];});
  const auto i=static_cast<std::size_t>(it-points_.begin()-1);
  const double width=points_[i+1][0]-points_[i][0];
  const double b=(x-points_[i][0])/width, a=1-b;
  return pin(a*points_[i][1]+b*points_[i+1][1]+
      ((a*a*a-a)*second_[i]+(b*b*b-b)*second_[i+1])*width*width/6);
}
} // namespace

FloatImage render_dcp_base(const FloatImage& input, const DcpRenderContext& context,
                           float exposure_ev) {
  input.require_consistent("DCP input");
  if (input.channels!=3 || !context.profile) throw std::invalid_argument("DCP render requires RGB and a profile");
  const auto& profile=*context.profile;
  const Tone tone(profile.tone_curve);
  const double exposure=exposure_ev+context.baseline_exposure+profile.baseline_exposure_offset;
  const double white=std::exp2(-std::max(0.0,exposure));
  // SDK sample defaults: Shadows=5, ShadowScale=1, Stage3Gain=1. Sensor
  // black correction has already happened in LibRaw and is never disabled.
  const double black=profile.default_black_render_none ? 0 : std::min(0.005,0.99*white);
  const double slope=1/(white-black), radius=std::min(0.5*black,1/(16*slope));
  const double negative_gain=std::exp2(std::min(0.0,exposure));
  const double qa=16.0/9*(1-negative_gain), qb=negative_gain-0.5*qa, qc=1-qa-qb;
  // Sample the combined exposure/tone function once, not a spline search per
  // pixel. RGB tone maps min and max, interpolating the middle channel.
  std::array<double,4097> curve{};
  for (std::size_t i=0;i<curve.size();++i) {
    double x=double(i)/(curve.size()-1);
    if (exposure<0) x=x<=0.25 ? x*negative_gain : (qa*x+qb)*x+qc;
    curve[i]=tone(x);
  }
  const auto lookup=[&](double x) {
    const double p=pin(x)*(curve.size()-1);
    const auto i=std::min(static_cast<std::size_t>(p),curve.size()-2);
    return std::lerp(curve[i],curve[i+1],p-i);
  };
  const auto& map1=profile.hue_sat_maps[0];
  const auto& map2=profile.hue_sat_maps[1];
  const double weight=std::clamp(context.illuminant_weight,0.0,1.0);
  // Both illuminants use the same DCP grid. Interpolation is linear in its
  // deltas, so blend the small table once instead of sampling two grids for
  // every pixel. Keep the profile immutable for other photographs/threads.
  DcpHueSatMap blended;
  const DcpHueSatMap* hue_sat = map1.values.empty() ? &map2 : &map1;
  if (!map1.values.empty() && !map2.values.empty()) {
    if (map1.dims != map2.dims || map1.srgb_encoding != map2.srgb_encoding ||
        map1.values.size() != map2.values.size())
      throw std::invalid_argument("DCP illuminant maps must share a grid and encoding");
    if (weight == 0) hue_sat = &map2;
    else if (weight < 1) {
      blended.dims = map1.dims;
      blended.srgb_encoding = map1.srgb_encoding;
      blended.values.resize(map1.values.size());
      for (std::size_t i = 0; i < blended.values.size(); ++i)
        for (unsigned c = 0; c < 3; ++c)
          blended.values[i][c] = static_cast<float>(std::lerp(
              double(map2.values[i][c]), double(map1.values[i][c]), weight));
      hue_sat = &blended;
    }
  }
  FloatImage output(input.width,input.height,3);
  parallel_for_rows(input.height,[&](std::uint32_t y) {
    for (std::uint32_t x=0;x<input.width;++x) {
      const auto i=(static_cast<std::size_t>(y)*input.width+x)*3;
      RGB rgb=transform(to_pro,{input.pixels[i],input.pixels[i+1],input.pixels[i+2]});
      for (auto& c:rgb) c=pin(c);
      rgb=apply_map(rgb,*hue_sat);
      for (auto& c:rgb) {
        if (c<=black-radius) c=0;
        else if (c>=black+radius) c=pin((c-black)*slope);
        else { const double d=c-(black-radius); c=slope*d*d/(4*radius); }
      }
      rgb=apply_map(rgb,profile.look_table);
      const double lo=std::min({rgb[0],rgb[1],rgb[2]}), hi=std::max({rgb[0],rgb[1],rgb[2]});
      const double low=lookup(lo), high=lookup(hi);
      for (auto& c:rgb) c=hi>lo ? low+(high-low)*(c-lo)/(hi-lo) : low;
      rgb=transform(to_p3,rgb);
      for (int c=0;c<3;++c) output.pixels[i+c]=static_cast<float>(pin(rgb[c]));
    }
  });
  return output;
}
void apply_dcp_adjustments(FloatImage& base, const LookOptions& look) {
  base.require_consistent("DCP adjustments");
  if (base.channels != 3) throw std::invalid_argument("DCP adjustments require RGB");
  validate_look_options(look);
  if (look.contrast == 1.0F && look.vibrance == 0.0F) return;
  auto chroma = look;
  chroma.pop = 0.0F;
  parallel_for_rows(base.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < base.width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * base.width + x) * 3;
      const float r = base.pixels[i], g = base.pixels[i+1], b = base.pixels[i+2];
      const float luminance = p3_luminance(r, g, b);
      // Contrast pivots at middle gray and scales all channels together.
      // This is an explicit grade, with no second toe, automatic exposure,
      // default photographic contrast, or highlight desaturation.
      const float adjusted = look.contrast == 1.0F ? luminance :
          std::clamp(0.18F * std::pow(std::max(0.0F, luminance) / 0.18F,
                                     look.contrast), 0.0F, 1.0F);
      const auto rgb = render_common_chroma(r, g, b, luminance,
                                            adjusted, adjusted, 1.0F, chroma);
      for (int c = 0; c < 3; ++c) base.pixels[i+c] = rgb[c];
    }
  });
}
} // namespace hyperdr

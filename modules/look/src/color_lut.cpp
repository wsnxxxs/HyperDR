#include "hyperdr/look/color_lut.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <locale>
#include <sstream>
#include <stdexcept>

namespace hyperdr {
const char* lut_space_name(LutSpace s) {
  switch (s) {
    case LutSpace::Srgb: return "srgb";
    case LutSpace::DisplayP3: return "p3";
    case LutSpace::Rec709: return "rec709";
    case LutSpace::Hlg: return "hlg";
    case LutSpace::Pq: return "pq";
    case LutSpace::SLog3: return "slog3-sgamut3cine";
  }
  return "unknown";
}
std::optional<LutSpace> lut_space_from_name(std::string_view name) {
  for (auto s : {LutSpace::Srgb, LutSpace::DisplayP3, LutSpace::Rec709,
                 LutSpace::Hlg, LutSpace::Pq, LutSpace::SLog3})
    if (name == lut_space_name(s)) return s;
  return std::nullopt;
}
namespace {
bool sdr_space(LutSpace s) {
  return s == LutSpace::Srgb || s == LutSpace::DisplayP3 || s == LutSpace::Rec709;
}
void refresh_stats(PhotoRenditions& image) {
  measure_rendition_stats(image.stats, image.sdr, image.hdr, image.below_knee);
}
std::array<float,3> multiply(std::array<float,3> a, const std::array<float,9>& m) {
  return {m[0]*a[0]+m[1]*a[1]+m[2]*a[2], m[3]*a[0]+m[4]*a[1]+m[5]*a[2],
      m[6]*a[0]+m[7]*a[1]+m[8]*a[2]};
}
// Derived from Sony's published S-Gamut3.Cine xy primaries with D65 white.
constexpr std::array<float,9> to_cine{.77815155F,.11728624F,.10456221F,
  .07226832F,.75994794F,.16778375F,.02346043F,.06084114F,.91569844F};
constexpr std::array<float,9> from_cine{1.30640907F,-.19250497F,-.11390411F,
  -.11858463F,1.35294405F,-.23435942F,-.02559149F,-.08496073F,1.11055222F};
float slog3_encode(float x) {
  return x >= .01125F ? (420 + 261.5F*std::log10((x+.01F)/.19F))/1023 :
      (x*(171.2102946929F-95)/.01125F+95)/1023;
}
float slog3_decode(float x) {
  return x >= 171.2102946929F/1023 ? std::pow(10.0F,(x*1023-420)/261.5F)*.19F-.01F :
      (x*1023-95)*.01125F/(171.2102946929F-95);
}
}

ColorLut read_color_lut(const std::filesystem::path& path) {
  std::ifstream file(path);
  if (!file) throw std::invalid_argument("cannot open colour LUT");
  ColorLut lut;
  std::string line;
  unsigned line_number = 0;
  auto bad = [&](const char* message) { throw std::invalid_argument(
      "colour LUT line " + std::to_string(line_number) + ": " + message); };
  while (std::getline(file,line)) {
    ++line_number;
    if (line_number == 1 && line.starts_with("\xEF\xBB\xBF")) line.erase(0,3);
    if (const auto hash=line.find('#'); hash!=std::string::npos) line.resize(hash);
    std::istringstream in(line); in.imbue(std::locale::classic());
    std::string key;
    if (!(in>>key)) continue;
    if (key == "TITLE") { std::getline(in,lut.title); continue; }
    if (key == "LUT_1D_SIZE" || key == "LUT_3D_SIZE") {
      if (lut.size) bad("combined 1D+3D tables are not supported; export a single cube");
      lut.three_dimensional = key == "LUT_3D_SIZE";
      if (!(in>>lut.size) || lut.size < 2 || lut.size > (lut.three_dimensional ? 129U : 65536U)) bad("invalid table size");
    } else if (key == "DOMAIN_MIN" || key == "DOMAIN_MAX") {
      auto& a=key=="DOMAIN_MIN"?lut.domain_min:lut.domain_max;
      if (!(in>>a[0]>>a[1]>>a[2])) bad("expected three domain values");
    } else if (key == "LUT_1D_INPUT_RANGE" || key == "LUT_3D_INPUT_RANGE") {
      float lo,hi;
      if (!(in>>lo>>hi)) bad("expected input minimum and maximum");
      lut.domain_min.fill(lo); lut.domain_max.fill(hi);
    } else {
      if (!lut.size) bad("expected LUT_1D_SIZE or LUT_3D_SIZE before data");
      std::istringstream row(line); row.imbue(std::locale::classic());
      std::array<float,3> rgb;
      std::string extra;
      if (!(row>>rgb[0]>>rgb[1]>>rgb[2]) || row>>extra) bad("expected three numeric samples or a supported .cube header");
      for (float c:rgb) if (!std::isfinite(c)) bad("samples must be finite");
      lut.values.push_back(rgb);
      const auto expected=lut.three_dimensional ? static_cast<std::size_t>(lut.size)*lut.size*lut.size : lut.size;
      if (lut.values.size()>expected) bad("too many samples");
      continue;
    }
    std::string extra;
    if (in>>extra) bad("unexpected header data");
  }
  const auto expected=lut.three_dimensional ? static_cast<std::size_t>(lut.size)*lut.size*lut.size : lut.size;
  if (!lut.size || lut.values.size()!=expected) bad("incomplete table");
  for (int c=0;c<3;++c) if (!(std::isfinite(lut.domain_min[c]) && std::isfinite(lut.domain_max[c]) && lut.domain_max[c]>lut.domain_min[c])) bad("invalid domain");
  return lut;
}

std::array<float,3> ColorLut::sample(std::array<float,3> rgb) const {
  std::array<unsigned,3> lo,hi;
  std::array<float,3> t;
  for(int c=0;c<3;++c) {
    const float p=std::clamp((rgb[c]-domain_min[c])/(domain_max[c]-domain_min[c]),0.0F,1.0F)*(size-1);
    lo[c]=static_cast<unsigned>(p); hi[c]=std::min(lo[c]+1,size-1); t[c]=p-lo[c];
  }
  std::array<float,3> out;
  for(int c=0;c<3;++c) {
    if (!three_dimensional) { out[c]=std::lerp(values[lo[c]][c],values[hi[c]][c],t[c]); continue; }
    const auto at=[&](unsigned r,unsigned g,unsigned b) {return values[(static_cast<std::size_t>(b)*size+g)*size+r][c];};
    out[c]=std::lerp(
        std::lerp(std::lerp(at(lo[0],lo[1],lo[2]),at(hi[0],lo[1],lo[2]),t[0]),
                  std::lerp(at(lo[0],hi[1],lo[2]),at(hi[0],hi[1],lo[2]),t[0]),t[1]),
        std::lerp(std::lerp(at(lo[0],lo[1],hi[2]),at(hi[0],lo[1],hi[2]),t[0]),
                  std::lerp(at(lo[0],hi[1],hi[2]),at(hi[0],hi[1],hi[2]),t[0]),t[1]),t[2]);
  }
  return out;
}
std::array<float,3> encode_lut_space(std::array<float,3> rgb, LutSpace space) {
  if (space==LutSpace::SLog3) rgb=multiply(rgb,to_cine);
  else if (space==LutSpace::Hlg || space==LutSpace::Pq) rgb=p3_to_rec2020(rgb[0],rgb[1],rgb[2]);
  else if (space!=LutSpace::DisplayP3) {
    rgb=compress_linear_p3_to_srgb(rgb[0],rgb[1],rgb[2]);
    rgb=linear_p3_to_rec709(rgb[0],rgb[1],rgb[2]);
  }
  for(auto& c:rgb) {
    switch(space) {
      case LutSpace::SLog3:c=slog3_encode(c);break;
      case LutSpace::Hlg:c=hlg_oetf(c);break;
      case LutSpace::Pq:c=pq_oetf(c);break;
      case LutSpace::Rec709:c=std::pow(std::max(0.0F,c),1/2.4F);break;
      default:c=srgb_oetf(c);break;
    }
  }
  return rgb;
}
std::array<float,3> decode_lut_space(std::array<float,3> rgb, LutSpace space) {
  for(auto& c:rgb) {
    switch(space) {
      case LutSpace::SLog3:c=slog3_decode(c);break;
      case LutSpace::Hlg:c=hlg_inverse_oetf(std::clamp(c,0.0F,1.0F));break;
      case LutSpace::Pq:c=pq_eotf(std::clamp(c,0.0F,1.0F));break;
      case LutSpace::Rec709:c=std::pow(std::max(0.0F,c),2.4F);break;
      default:c=srgb_eotf(c);break;
    }
  }
  if (space==LutSpace::SLog3) return multiply(rgb,from_cine);
  if (space==LutSpace::Hlg || space==LutSpace::Pq) return rec2020_to_linear_p3(rgb[0],rgb[1],rgb[2]);
  if (space!=LutSpace::DisplayP3) return rec709_to_linear_p3(rgb[0],rgb[1],rgb[2]);
  return rgb;
}
void validate_color_lut_options(const ColorLutOptions& o) {
  if (!std::isfinite(o.strength) || o.strength<0 || o.strength>1) throw std::invalid_argument("LUT strength must be in [0,1]");
  if (o.path.empty()) return;
  if (sdr_space(o.input) && !sdr_space(o.output)) throw std::invalid_argument("SDR creative LUTs require an SDR output space");
  if (o.input!=LutSpace::SLog3 && o.output==LutSpace::SLog3) throw std::invalid_argument("S-Log3 output requires a scene-referred S-Log3 LUT input");
}

void apply_rendition_lut(PhotoRenditions& out, const ColorLutOptions& grade, const ColorLut* supplied) {
  validate_color_lut_options(grade);
  if(grade.path.empty() || grade.strength==0) return;
  if(!sdr_space(grade.input)) throw std::invalid_argument("AI/external gain requires an SDR creative LUT");
  const auto owned=supplied ? ColorLut{} : read_color_lut(grade.path);
  const auto& lut=supplied?*supplied:owned;
  const float peak=std::exp2(out.stats.headroom_stops);
  parallel_for_rows(out.sdr.height,[&](std::uint32_t y) {
    for (std::uint32_t x=0;x<out.sdr.width;++x) {
      const auto i=(static_cast<std::size_t>(y)*out.sdr.width+x)*3;
      const std::array<float,3> before{out.sdr.pixels[i],out.sdr.pixels[i+1],out.sdr.pixels[i+2]};
      const float base_y=p3_luminance(before[0],before[1],before[2]);
      // At black there is no measured ratio. Regularize toward unity so a
      // lifted black meets neighbouring dark pixels continuously.
      const float ratio=out.hdr.pixels.empty()?1:
          (p3_luminance(out.hdr.pixels[i],out.hdr.pixels[i+1],out.hdr.pixels[i+2])+1e-6F)/(base_y+1e-6F);
      auto rgb=decode_lut_space(lut.sample(encode_lut_space(before,grade.input)),grade.output);
      for(auto& c:rgb) c=std::clamp(c,0.0F,1.0F);
      if(out.clamp_srgb) rgb=compress_linear_p3_to_srgb(rgb[0],rgb[1],rgb[2]);
      // Construct the full-grade endpoints first. The HDR source can have a
      // different hue from SDR, so each rendition blends from its own RGB.
      for(int c=0;c<3;++c) {
        out.sdr.pixels[i+c]=std::lerp(before[c],rgb[c],grade.strength);
        if(!out.hdr.pixels.empty()) out.hdr.pixels[i+c]=std::lerp(
            out.hdr.pixels[i+c],std::min(peak,rgb[c]*ratio),grade.strength);
      }
    }
  });
  refresh_stats(out);
}

PhotoRenditions render_graded_photo(const FloatImage& source,
    const RenderOptions& requested_options, const CaptureMetadata& capture,
    const InputDescription& input, RenderTarget target, const ColorLutOptions& grade,
    const ColorLut* supplied, const PhotographicAnalysis* analysis, GainMapPreparation* preparation) {
  validate_color_lut_options(grade);
  const auto options=render_options_for_target(requested_options,target);
  const auto baseline=[&]() {return render_renditions(source,options,capture,input,target,analysis,preparation);};
  if (grade.path.empty() || grade.strength==0) return baseline();
  const auto owned=supplied ? ColorLut{} : read_color_lut(grade.path);
  const auto& lut=supplied?*supplied:owned;
  const auto transform_rgb=[&](std::array<float,3> rgb) {
    return decode_lut_space(lut.sample(encode_lut_space(rgb,grade.input)),grade.output);
  };
  const auto transform=[&](FloatImage& image) {
    parallel_for_rows(image.height,[&](std::uint32_t y) {
      for (std::uint32_t x=0;x<image.width;++x) {
        const auto i=(static_cast<std::size_t>(y)*image.width+x)*3;
        const auto out=transform_rgb({image.pixels[i],image.pixels[i+1],image.pixels[i+2]});
        for(int c=0;c<3;++c) image.pixels[i+c]=out[c];
      }
    });
  };
  if (sdr_space(grade.input)) {
    auto out=baseline();
    apply_rendition_lut(out,grade,&lut);
    return out;
  }
  FloatImage working;
  FloatImage developed_sdr;
  std::vector<std::uint8_t> developed_below_knee;
  float exposure_ev=0;
  float working_headroom=1;
  std::optional<float> developed_stops;
  if(grade.input==LutSpace::SLog3) {
    if(input.domain!=InputDomain::kSceneReferred) throw std::invalid_argument("S-Log3 LUT input requires a RAW scene; an SDR/HLG/PQ photograph is already rendered");
    exposure_ev=photographic_exposure_ev(source,options,capture);
    working=source;
    for(auto& c:working.pixels) c*=std::exp2(exposure_ev);
    working_headroom=0;
    for(std::size_t i=0;i<working.pixels.size();i+=3)
      working_headroom=std::max(working_headroom,
          p3_luminance(working.pixels[i],working.pixels[i+1],working.pixels[i+2]));
  } else if(input.domain==InputDomain::kDisplayReferredHdr) {
    // Grade original HDR highlights before the user's output headroom limit.
    working=source;
    exposure_ev=std::clamp((options.auto_exposure?0:options.exposure_ev)+options.exposure_bias_ev,-10.0F,10.0F);
    for(auto& c:working.pixels) c*=std::exp2(exposure_ev);
    working_headroom=input.headroom*std::exp2(exposure_ev);
  } else {
    // HLG/PQ specifies the LUT's signal encoding, not a request to expand SDR.
    // Develop only the requested rendition before entering that encoding.
    auto developed=render_renditions(source,options,capture,input,target,analysis,preparation);
    if (target==RenderTarget::Hdr) {
      developed_sdr=std::move(developed.sdr);
      developed_below_knee=std::move(developed.below_knee);
    }
    working=target==RenderTarget::Sdr ? std::move(developed.sdr) : std::move(developed.hdr);
    exposure_ev=developed.stats.exposure_ev;
    working_headroom=developed.stats.headroom_linear;
    if(target==RenderTarget::Hdr) developed_stops=developed.stats.headroom_stops;
  }
  transform(working);
  InputDescription graded_input;
  if(sdr_space(grade.output)) graded_input={InputDomain::kDisplayReferredSdr,1};
  else if(grade.output==LutSpace::SLog3) graded_input={InputDomain::kSceneReferred,1};
  else {
    // Carry the photo's neutral peak through the same LUT, including exposure
    // and domain clamping. An identity/conversion LUT retains declared range
    // even if this frame never reaches it; a tone LUT can lower or raise it.
    // Measure luminance: an out-of-P3 RGB component does not by itself mean
    // more photo headroom. Final rendering handles the colour gamut separately.
    const auto anchor=transform_rgb({working_headroom,working_headroom,working_headroom});
    float headroom=std::max(1.0F,p3_luminance(anchor[0],anchor[1],anchor[2]));
    for(std::size_t i=0;i<working.pixels.size();i+=3)
      headroom=std::max(headroom,
          p3_luminance(working.pixels[i],working.pixels[i+1],working.pixels[i+2]));
    graded_input={headroom>1 ? InputDomain::kDisplayReferredHdr : InputDomain::kDisplayReferredSdr,headroom};
  }
  auto adjusted=options;
  adjusted.auto_exposure=false; adjusted.exposure_ev=0; adjusted.exposure_bias_ev=0;
  if((grade.output==LutSpace::Hlg || grade.output==LutSpace::Pq) && graded_input.headroom==1) {
    // The LUT removed HDR range. Keep that result even in an HDR container,
    // rather than expanding the newly classified SDR image again.
    adjusted.gain_strength=0;
  }
  if(developed_stops && graded_input.domain==InputDomain::kDisplayReferredHdr) {
    // RAW/SDR already received the requested HDR expansion before this LUT.
    // Only enforce that output budget here, without multiplying strength again.
    adjusted.auto_headroom=false; adjusted.headroom_stops=*developed_stops;
    adjusted.gain_strength=1;
  }
  auto out=render_renditions(working,adjusted,capture,graded_input,target);
  if (!developed_sdr.pixels.empty()) {
    // Grade the existing SDR endpoint independently. Re-splitting the HDR
    // endpoint would apply a second, different tone map even for identity LUTs.
    transform(developed_sdr);
    InputDescription sdr_input{InputDomain::kDisplayReferredSdr,1};
    if (grade.output==LutSpace::Hlg || grade.output==LutSpace::Pq) {
      const auto white=transform_rgb({1,1,1});
      float headroom=std::max(1.0F,p3_luminance(white[0],white[1],white[2]));
      for (std::size_t i=0;i<developed_sdr.pixels.size();i+=3)
        headroom=std::max(headroom,p3_luminance(developed_sdr.pixels[i],developed_sdr.pixels[i+1],developed_sdr.pixels[i+2]));
      if (headroom>1) sdr_input={InputDomain::kDisplayReferredHdr,headroom};
    }
    out.sdr=render_renditions(developed_sdr,adjusted,capture,sdr_input,RenderTarget::Sdr).sdr;
    out.below_knee=std::move(developed_below_knee);
  }
  out.stats.exposure_ev=exposure_ev;
  if(grade.strength<1) {
    auto original=baseline();
    for(std::size_t i=0;i<out.sdr.pixels.size();++i) out.sdr.pixels[i]=std::lerp(original.sdr.pixels[i],out.sdr.pixels[i],grade.strength);
    for(std::size_t i=0;i<out.hdr.pixels.size();++i) out.hdr.pixels[i]=std::lerp(original.hdr.pixels[i],out.hdr.pixels[i],grade.strength);
    out.stats.headroom_linear=std::lerp(original.stats.headroom_linear,
        out.stats.headroom_linear,grade.strength);
    out.stats.headroom_stops=std::log2(out.stats.headroom_linear);
  }
  refresh_stats(out);
  return out;
}
}  // namespace hyperdr

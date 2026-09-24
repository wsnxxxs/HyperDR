#include "hyperdr/look/dcp_render.hpp"
#include "hyperdr/look/options.hpp"
#include "hyperdr/look/rendition.hpp"
#include "hyperdr/image/color.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {
using RGB=std::array<double,3>;
void require(bool condition,const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void close(double actual,double expected,const char* message,double tolerance=2e-5) {
  require(std::abs(actual-expected)<tolerance,message);
}
std::shared_ptr<hyperdr::DcpProfile> identity() {
  auto p=std::make_shared<hyperdr::DcpProfile>();
  p->default_black_render_none=true;
  p->tone_curve={{{0,0}},{{1,1}}};
  return p;
}
hyperdr::FloatImage pixel(RGB value) {
  hyperdr::FloatImage image(1,1,3);
  for (int c=0;c<3;++c) image.pixels[c]=static_cast<float>(value[c]);
  return image;
}
RGB pro_to_p3(RGB v) {
  return {1.632564475640*v[0]-.379768609138*v[1]-.252795866503*v[2],
    -.153701875180*v[0]+1.166713085630*v[1]-.013011210451*v[2],
    .010393259036*v[0]-.062807871342*v[1]+1.052414612306*v[2]};
}
RGB p3_to_pro(const hyperdr::FloatImage& image) {
  const auto& v=image.pixels;
  return {.631691220187*v[0]+.213928184843*v[1]+.154380594970*v[2],
    .083204316859*v[0]+.885857509646*v[1]+.030938173495*v[2],
    -.001272734565*v[0]+.050755104337*v[1]+.950517630228*v[2]};
}
hyperdr::DcpHueSatMap map(float value_scale,bool encoded=false) {
  hyperdr::DcpHueSatMap result;
  result.dims={4,2,2};
  result.values.assign(16,{0,1,value_scale});
  result.srgb_encoding=encoded;
  return result;
}
void neutral_and_exposure() {
  auto p=identity();
  const auto input=pixel({.1,.1,.1});
  hyperdr::DcpRenderContext context{p,1,0};
  auto out=hyperdr::render_dcp_base(input,context);
  for (float c:out.pixels) close(c,.1,"neutral identity / D50 adaptation");
  p->baseline_exposure_offset=-.35F;
  out=hyperdr::render_dcp_base(input,context);
  for (float c:out.pixels) close(c,.1*std::exp2(-.35),"profile offset applied once");
  context.baseline_exposure=.35F;
  out=hyperdr::render_dcp_base(input,context);
  for (float c:out.pixels) close(c,.1,"baseline and profile offset cancel");
  out=hyperdr::render_dcp_base(input,context,1);
  for (float c:out.pixels) close(c,.2,"user exposure applied once");
  context.baseline_exposure=0;
  p->baseline_exposure_offset=0;
  p->default_black_render_none=false;
  out=hyperdr::render_dcp_base(input,context);
  for (float c:out.pixels) close(c,(.1-.005)/.995,"SDK automatic render black");
  p->default_black_render_none=true;
  p->tone_curve.clear();
  out=hyperdr::render_dcp_base(input,context);
  require(out.pixels[0]>.1F,"missing curve must use ACR3 instead of identity");
}
void table_interpolation_and_encoding() {
  auto p=identity();
  const auto input=pixel({.1,.1,.1});
  hyperdr::DcpRenderContext context{p,1,0};
  p->hue_sat_maps[0]=map(1);
  p->hue_sat_maps[1]=map(.5);
  for (double weight:{0.,.5,1.}) {
    context.illuminant_weight=weight;
    const auto out=hyperdr::render_dcp_base(input,context);
    close(out.pixels[0],.1*(.5+.5*weight),"dual illuminant map interpolation");
  }
  // Vary every grid axis so preblending is checked against an independently
  // evaluated trilinear function, not just constant identity tables.
  for (unsigned z=0;z<2;++z) for(unsigned h=0;h<4;++h) for(unsigned s=0;s<2;++s) {
    const auto i=(z*4+h)*2+s;
    p->hue_sat_maps[0].values[i][2]=.6F+.1F*h+.05F*s+.02F*z;
    p->hue_sat_maps[1].values[i][2]=.8F-.03F*h-.04F*s-.01F*z;
  }
  context.illuminant_weight=.37;
  const auto blended=p3_to_pro(hyperdr::render_dcp_base(pixel(pro_to_p3({.3,.2,.1})),context));
  const double scale=std::lerp(.8-.03/3-.04*2/3-.01*.3,
                               .6+.1/3+.05*2/3+.02*.3,.37);
  close(blended[0],.3*scale,"preblended illuminant grid preserves trilinear sampling");
  close(blended[1],.2*scale,"preblended map preserves channel ratios");
  p->hue_sat_maps={};
  p->look_table=map(.8F,true);
  const auto colored=pixel(pro_to_p3({.2,.15,.1}));
  const auto out=p3_to_pro(hyperdr::render_dcp_base(colored,context));
  const double encoded=1.055*std::pow(.2,1/2.4)-.055;
  const double value=std::pow((encoded*.8+.055)/1.055,2.4);
  close(out[0],value,"encoding applies to HSV V before value scale");
  close(out[1]/out[0],.75,"V encoding preserves RGB ratio / HSV saturation");
  close(out[2]/out[0],.5,"V encoding does not encode RGB channels");
  // Hue approaching 360 degrees must approach the hue-zero slice.
  p->look_table=map(1);
  for (unsigned z=0;z<2;++z)
    for (unsigned h=0;h<4;++h)
      for (unsigned s=0;s<2;++s)
        p->look_table.values[(z*4+h)*2+s][2]=h==0?.8F:.5F;
  const auto a=hyperdr::render_dcp_base(pixel(pro_to_p3({.3,.2,.200001})),context);
  const auto b=hyperdr::render_dcp_base(pixel(pro_to_p3({.3,.200001,.2})),context);
  for (int c=0;c<3;++c) close(a.pixels[c],b.pixels[c],"hue wrap is continuous");
}
void rgb_tone_semantics() {
  auto p=identity();
  p->tone_curve={{{0,0}},{{.5,.7}},{{1,1}}};
  hyperdr::DcpRenderContext context{p,1,0};
  const auto gray=hyperdr::render_dcp_base(pixel({.5,.5,.5}),context);
  for (float c:gray.pixels) close(c,.7,"spline passes through control point");
  const auto low=hyperdr::render_dcp_base(pixel({.1,.1,.1}),context).pixels[0];
  const auto high=hyperdr::render_dcp_base(pixel({.3,.3,.3}),context).pixels[0];
  const auto rgb=p3_to_pro(hyperdr::render_dcp_base(pixel(pro_to_p3({.3,.2,.1})),context));
  close(rgb[0],high,"RGB tone maximum");
  close(rgb[2],low,"RGB tone minimum");
  close(rgb[1],(high+low)*.5,"RGB tone interpolates middle channel");
}
void explicit_adjustments() {
  const auto original = pixel({.3,.2,.15});
  auto adjusted = original;
  hyperdr::LookOptions look;
  look.contrast = 1;
  look.vibrance = 0;
  hyperdr::apply_dcp_adjustments(adjusted,look);
  require(adjusted.pixels == original.pixels,"neutral DCP adjustments are exact identity");
  look.contrast = 1.2F;
  hyperdr::apply_dcp_adjustments(adjusted,look);
  require(adjusted.pixels[0] > original.pixels[0],"explicit contrast changes DCP base");
  close(adjusted.pixels[0]/adjusted.pixels[1],1.5,"contrast preserves channel ratios");
  adjusted = original;
  look.contrast = 1;
  look.vibrance = .3F;
  hyperdr::apply_dcp_adjustments(adjusted,look);
  require(adjusted.pixels[0]-adjusted.pixels[2] >
          original.pixels[0]-original.pixels[2],"explicit vibrance increases chroma");
  close(hyperdr::p3_luminance(adjusted.pixels[0],adjusted.pixels[1],adjusted.pixels[2]),
        hyperdr::p3_luminance(original.pixels[0],original.pixels[1],original.pixels[2]),
        "vibrance preserves luminance");
}
void attached_xmp_look() {
  auto p=identity();
  p->tone_curve={{{0,0}},{{.25,.5}},{{1,1}}};
  const hyperdr::DcpRenderContext context{p,1,0};
  const auto input=pixel({.25,.25,.25});
  const auto standard=hyperdr::render_dcp_base(input,context);
  close(standard.pixels[0],.5,"DCP tone precedes attached XMP look");
  p->xmp_look_table=map(.8F);
  const auto table_only=hyperdr::render_dcp_base(input,context);
  close(table_only.pixels[0],.4,"attached XMP look table follows DCP tone");
  p->xmp_tone_curve={{{0,0}},{{.4,.6}},{{1,1}}};
  const auto with_tone=hyperdr::render_dcp_base(input,context);
  close(with_tone.pixels[0],.6,"attached XMP tone follows its look table");
  p->xmp_look_table={};
  p->xmp_tone_curve.clear();
  const auto restored=hyperdr::render_dcp_base(input,context);
  require(restored.pixels==standard.pixels,"empty XMP fields leave DCP pixels unchanged");
}
void dcp_scene_highlights() {
  auto p=identity();
  auto context=std::make_shared<hyperdr::DcpRenderContext>(
      hyperdr::DcpRenderContext{p,1,0});
  hyperdr::InputDescription input{hyperdr::InputDomain::kSceneReferred,1};
  input.raw_profile=context;
  hyperdr::RenderOptions options;
  options.auto_headroom=false;
  options.headroom_stops=2;
  options.look.contrast=1;
  options.look.vibrance=0;
  hyperdr::FloatImage scene(4,1,3);
  for (int x=0;x<4;++x)
    for (int c=0;c<3;++c) scene.at(x,0,c)=std::array<float,4>{.5F,1.1F,1.5F,2.0F}[x];
  const auto sdr=hyperdr::render_renditions(scene,options,{},input,hyperdr::RenderTarget::Sdr);
  const auto hdr=hyperdr::render_renditions(scene,options,{},input,hyperdr::RenderTarget::Hdr);
  require(hdr.sdr.pixels==sdr.sdr.pixels,"DCP SDR base must remain unchanged in HDR render");
  close(hdr.sdr.at(1,0,0),hdr.sdr.at(3,0,0),"DCP SDR highlights remain clipped");
  require(hdr.hdr.at(1,0,0)<hdr.hdr.at(2,0,0) &&
      hdr.hdr.at(2,0,0)<hdr.hdr.at(3,0,0),
      "DCP HDR must retain distinct RAW highlight intensities");
  require(hdr.hdr.at(0,0,0)==hdr.sdr.at(0,0,0),
      "a scene with real highlights keeps below-white pixels at their DCP base");
  hyperdr::FloatImage ramp(7,1,3);
  constexpr std::array<float,7> levels{.8F,.95F,1.0F,1.05F,1.1F,1.5F,2.0F};
  for (int x=0;x<7;++x)
    for (int c=0;c<3;++c) ramp.at(x,0,c)=levels[x];
  const auto ramp_hdr=hyperdr::render_renditions(ramp,options,{},input,hyperdr::RenderTarget::Hdr);
  for (int x=1;x<7;++x)
    require(ramp_hdr.hdr.at(x,0,0)>=ramp_hdr.hdr.at(x-1,0,0),
        "DCP HDR must not create a downward seam at scene white");
  options.gain_strength=0;
  const auto zero=hyperdr::render_renditions(scene,options,{},input,hyperdr::RenderTarget::Hdr);
  require(zero.hdr.pixels==zero.sdr.pixels,"zero HDR strength must equal DCP SDR exactly");
  hyperdr::FloatImage below(2,1,3);
  below.pixels={.2F,.2F,.2F,.8F,.8F,.8F};
  options.gain_strength=1;
  const auto no_scene_highlights=hyperdr::render_renditions(
      below,options,{},input,hyperdr::RenderTarget::Hdr);
  const auto developed=hyperdr::render_dcp_base(below,*context);
  const auto old_path=hyperdr::render_renditions(developed,options,{},
      {hyperdr::InputDomain::kDisplayReferredSdr,1},hyperdr::RenderTarget::Hdr);
  require(no_scene_highlights.hdr.pixels==old_path.hdr.pixels,
      "a RAW without overrange highlights retains its previous HDR render");
}
}
int main() {
  try { neutral_and_exposure(); table_interpolation_and_encoding(); rgb_tone_semantics();
        explicit_adjustments(); attached_xmp_look(); dcp_scene_highlights(); }
  catch (const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}

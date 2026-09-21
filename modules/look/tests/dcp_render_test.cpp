#include "hyperdr/look/dcp_render.hpp"
#include "hyperdr/look/options.hpp"
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
}
int main() {
  try { neutral_and_exposure(); table_interpolation_and_encoding(); rgb_tone_semantics(); explicit_adjustments(); }
  catch (const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
}

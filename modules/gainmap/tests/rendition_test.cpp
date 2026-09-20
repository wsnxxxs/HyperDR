#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace hyperdr;
void require(bool ok, const char* message) { if(!ok) throw std::runtime_error(message); }

void test_model_grading() {
  GainMapResult original;
  original.base_linear=FloatImage(4,2,3);
  std::fill(original.base_linear.pixels.begin(),original.base_linear.pixels.end(),.2F);
  original.metadata.gain_min={-1,1}; original.metadata.gain_max={2,1};
  original.metadata.base_offset={1,10}; original.metadata.alternate_offset={1,20};
  original.metadata.alternate_headroom={2,1};
  original.headroom_stops=2; original.stats.headroom_stops=2; original.stats.headroom_linear=4;
  ColorLut lut; lut.size=2; lut.values={{.8F,.8F,.8F},{.8F,.8F,.8F}};
  for(bool rgb:{false,true}) {
    auto model=original;
    model.gain_map=FloatImage(2,1,rgb?3:1);
    model.gain_map.pixels=rgb ? std::vector<float>{0,.5F,1,1,.5F,0} : std::vector<float>{0,1};
    if(rgb) {
      model.metadata.flags|=0x80;
      model.metadata.channels={
          {{-1,1},{2,1},{1,1},{1,10},{1,20}},
          {{-2,1},{1,1},{1,1},{0,1},{0,1}},
          {{0,1},{2,1},{1,1},{1,20},{0,1}}};
    }
    const auto metadata=serialize_tmap_payload(model.metadata);
    for(float strength:{0.0F,.5F,1.0F}) {
      auto packed=model;
      ColorLutOptions grade{"test.cube",LutSpace::DisplayP3,LutSpace::DisplayP3,strength};
      const auto direct=render_graded_gain_map(packed,grade,true,&lut);
      require(serialize_tmap_payload(packed.metadata)==metadata && packed.gain_map.pixels==model.gain_map.pixels,
          "model LUT grading must preserve signed/channel gains and offsets");
      const auto reconstructed=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
      require(direct.hdr.pixels==reconstructed.pixels,"direct and gain-map formats must share the same graded HDR");
      const float base=std::lerp(.2F,srgb_eotf(.8F),strength);
      const auto first=model.metadata.channels.empty()?gain_map_channel(model.metadata,0):model.metadata.channels[0];
      const float expected=(base+rational_value(first.base_offset))*.5F-rational_value(first.alternate_offset);
      require(std::abs(direct.hdr.pixels[0]-expected)<1e-6F,"grading must apply the original affine model relation");
      auto sdr_model=model;
      const auto sdr=render_graded_gain_map(sdr_model,grade,false,&lut);
      require(sdr.hdr.pixels.empty() && sdr.sdr.pixels==direct.sdr.pixels,
          "SDR model output must share the graded base without an HDR allocation");
      require(packed.stats.rendered_peak==direct.stats.rendered_peak,"model export statistics must match reconstruction");
    }
  }
}

void test_final_gain_statistics() {
  FloatImage source(64,32,3);
  for(unsigned y=0;y<32;++y) for(unsigned x=0;x<64;++x) for(int c=0;c<3;++c)
    source.at(x,y,c)=x<32?.1F:4;
  RenderOptions options; options.auto_headroom=false; options.headroom_stops=3;
  auto photo=render_renditions(source,options,{}, {InputDomain::kDisplayReferredHdr,4},RenderTarget::Hdr);
  require(photo.stats.below_knee_relative_difference_max<1e-6F,"direct HDR must leave this dark field alone");
  // The cell-averaged packager is what renditions whose SDR endpoint carries
  // its own grade still use; an HDR source itself is packaged exactly below.
  photo.hdr_is_source=false;
  const auto packed=gain_map_from_renditions(photo);
  const auto hdr=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
  float peak=1, difference=0;
  for(unsigned y=0;y<32;++y) for(unsigned x=0;x<64;++x) {
    const float alternate=p3_luminance(hdr.at(x,y,0),hdr.at(x,y,1),hdr.at(x,y,2));
    peak=std::max(peak,alternate);
    if(x<32) difference=std::max(difference,std::abs(alternate/.1F-1));
  }
  require(difference>.4F,"fixture must expose bilinear spill into dark pixels");
  require(std::abs(packed.stats.below_knee_relative_difference_max-difference)<1e-5F,
      "gain-map report must measure the final interpolated dark-field change");
  require(std::abs(packed.stats.rendered_peak-peak)<1e-6F,"gain-map report must measure the reconstructed peak");
  require(std::abs(packed.stats.headroom_utilization-(peak-1)/(photo.stats.headroom_linear-1))<1e-6F,
      "headroom utilization must use the reconstructed peak");
}

void test_zero_and_spatial_gain() {
  FloatImage source(256,128,3);
  for(unsigned y=0;y<128;++y) for(unsigned x=0;x<256;++x) {
    const float v=x<240?.06F:8;
    source.at(x,y,0)=v; source.at(x,y,1)=v*.85F; source.at(x,y,2)=v*.7F;
  }
  RenderOptions options; options.auto_headroom=false;
  options.headroom_stops=2.5F; options.look.headroom_max_stops=2.5F;
  options.look.shoulder_start=.25F; options.look.diffuse_gain_floor=1;
  options.gain_strength=0;
  const auto base=render_renditions(source,options,{}, {},RenderTarget::Hdr);
  options.headroom_stops=0; options.look.headroom_max_stops=0;
  const auto zero=render_renditions(source,options,{}, {},RenderTarget::Hdr);
  require(base.stats.exposure_ev==zero.stats.exposure_ev,"HDR range must not alter RAW metering");
  require(base.sdr.pixels==zero.sdr.pixels && zero.sdr.pixels==zero.hdr.pixels,
      "zero gain must retain the same RAW base");
  const auto sdr=render_renditions(source,options,{}, {},RenderTarget::Sdr);
  require(sdr.sdr.pixels==base.sdr.pixels,"output format must preserve RAW base");
  options.headroom_stops=2.5F; options.look.headroom_max_stops=2.5F;
  for(auto domain:{InputDomain::kSceneReferred,InputDomain::kDisplayReferredSdr}) {
    if(domain==InputDomain::kDisplayReferredSdr)
      for(unsigned y=0;y<128;++y) for(unsigned x=0;x<256;++x) for(int c=0;c<3;++c)
        source.at(x,y,c)=(.01F+.99F*x/255)*(1-.15F*c);
    for(float strength:{0.0F,.4F,1.0F}) {
      options.gain_strength=strength;
      const InputDescription input{domain,1};
      const auto legacy=make_gain_map(source,options,{},input);
      const auto packed=gain_map_from_renditions(render_renditions(source,options,{},input,RenderTarget::Hdr));
      require(legacy.base_linear.pixels==packed.base_linear.pixels,"retained grid must preserve base");
      const auto old_hdr=reconstruct_gain_map(legacy.base_linear,legacy.gain_map,legacy.metadata,legacy.headroom_stops);
      const auto new_hdr=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
      for(std::size_t i=0;i<old_hdr.pixels.size();++i)
        require(std::abs(old_hdr.pixels[i]-new_hdr.pixels[i])<1e-5F,"packaging must not blur highlight edges again");
    }
  }
}
// A display-referred HDR photograph must come back out of its gain map as
// itself: a highlight beside a shadow keeps both its brightness and the
// shadow's, and a saturated highlight keeps its colour. The cell-averaged map
// gave the Sony HLG frame that motivated this its neighbours' gain and the SDR
// base's desaturated chroma, about a fifth of its highlight brightness lost.
void test_hdr_source_reconstructs_itself() {
  const float headroom=1000.0F/203.0F;
  FloatImage source(67,41,3);  // odd sizes: nothing may depend on a 2x grid
  for(unsigned y=0;y<41;++y) for(unsigned x=0;x<67;++x) {
    std::array<float,3> rgb{.02F,.02F,.02F};
    if(x>=30) rgb={headroom,headroom,headroom};            // hard edge to peak white
    if(x>=30 && y>=20) rgb={3.0F,.6F,.25F};                 // saturated, inside the volume
    if(x==66 && y==40) rgb={6.2F,.0F,.05F};                 // brighter channel than the headroom
    if(x<30 && y>=30) rgb={.4F*(x+1)/30,.3F,.2F};           // midtone ramp below the knee
    for(int c=0;c<3;++c) source.at(x,y,c)=rgb[c];
  }
  RenderOptions options; options.auto_headroom=false; options.headroom_stops=3;
  options.look.headroom_max_stops=3; options.look.shoulder_start=.25F;
  const InputDescription input{InputDomain::kDisplayReferredHdr,headroom};
  auto photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
  require(photo.hdr_is_source,"an HDR source's renditions must request exact packaging");
  const auto target_sdr=photo.sdr;
  const auto expected_hdr=photo.hdr;
  const auto packed=gain_map_from_renditions(photo);
  require(packed.gain_map.width==source.width && packed.gain_map.height==source.height,
      "an HDR source's gain map must be full resolution");
  require(rational_value(packed.metadata.gamma)==1 && rational_value(packed.metadata.gain_min)==0,
      "exact packaging stores linear, non-negative gain");
  require(packed.metadata.alternate_headroom.numerator==packed.metadata.gain_max.numerator &&
      packed.metadata.alternate_headroom.denominator==packed.metadata.gain_max.denominator,
      "the declared headroom is the stored gain maximum");
  require(packed.headroom_stops<=std::log2(headroom)+1e-3F,
      "saturated channels must not inflate the declared headroom past the photograph's");
  for(float v:packed.base_linear.pixels) require(v>=0 && v<=1,"the base must stay inside [0, 1]");
  const auto hdr=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
  float worst=0;
  for(unsigned y=0;y<41;++y) for(unsigned x=0;x<67;++x) {
    if(x==66 && y==40) continue;
    for(int c=0;c<3;++c) {
      const float want=expected_hdr.at(x,y,c), got=hdr.at(x,y,c);
      worst=std::max(worst,std::abs(got-want)/std::max(want,1e-3F));
    }
    const float base_y=p3_luminance(packed.base_linear.at(x,y,0),packed.base_linear.at(x,y,1),packed.base_linear.at(x,y,2));
    const float tone_y=p3_luminance(target_sdr.at(x,y,0),target_sdr.at(x,y,1),target_sdr.at(x,y,2));
    require(base_y<=tone_y*1.0001F+1e-6F,"the base is never brighter than the SDR tone map");
    require(base_y>=tone_y*.99F-1e-6F || x>=30,"below the highlights the base is the SDR tone map");
  }
  require(worst<2e-4F,"every in-volume HDR pixel must reconstruct exactly, edges included");
  require(std::abs(hdr.at(29,5,0)-.02F)<1e-6F,"the shadow beside a peak-white edge receives no gain");
  require(std::abs(hdr.at(40,25,0)/hdr.at(40,25,1)-5.0F)<1e-3F,"a saturated highlight keeps its chroma");
  const float over_want=p3_luminance(expected_hdr.at(66,40,0),expected_hdr.at(66,40,1),expected_hdr.at(66,40,2));
  const float over_got=p3_luminance(hdr.at(66,40,0),hdr.at(66,40,1),hdr.at(66,40,2));
  require(std::abs(over_got/over_want-1)<2e-3F,
      "a colour beyond the headroom keeps its luminance and gives up only excess chroma");
  require(packed.stats.below_knee_relative_difference_max<1e-4F,"the report sees no dark-field spill");
  require(std::abs(packed.stats.rendered_peak-headroom)<5e-3F,"the report sees the declared peak restored");

  // Grading that gives the SDR endpoint its own colour keeps the averaged map.
  photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
  photo.hdr_is_source=false;
  const auto averaged=gain_map_from_renditions(photo);
  require(averaged.gain_map.width<source.width,"graded renditions keep the low-frequency map");
}

// A Rec.2020 green outside P3 decodes with negative P3 components. The HDR
// rendition must fit it at its own luminance and Oklab hue rather than clamp
// each channel, which is what the decoder used to do before any gamut decision.
void test_hdr_source_outside_p3() {
  const float headroom=1000.0F/203.0F;
  const auto green=rec2020_to_linear_p3(0.0F,2.0F,0.0F);
  require(green[0]<0 && green[2]<0,"Rec.2020 green must keep its negative P3 components");
  FloatImage source(4,4,3);
  for(unsigned y=0;y<4;++y) for(unsigned x=0;x<4;++x) for(int c=0;c<3;++c) source.at(x,y,c)=green[c];
  RenderOptions options; options.auto_headroom=false; options.headroom_stops=std::log2(headroom);
  const InputDescription input{InputDomain::kDisplayReferredHdr,headroom};
  const auto photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
  const float peak=std::exp2(photo.stats.headroom_stops);
  for(float v:photo.sdr.pixels) require(v>=-1e-6F && v<=1+1e-6F,"the SDR rendition of an out-of-P3 colour must be inside [0, 1]");
  for(float v:photo.hdr.pixels) require(v>=-1e-6F && v<=peak*(1+1e-5F),"the HDR rendition of an out-of-P3 colour must be inside its headroom");
  const std::array<float,3> hdr{photo.hdr.at(1,1,0),photo.hdr.at(1,1,1),photo.hdr.at(1,1,2)};
  const float source_y=p3_luminance(green[0],green[1],green[2]);
  require(std::abs(p3_luminance(hdr[0],hdr[1],hdr[2])/std::min(source_y,peak)-1)<1e-3F,
      "the HDR rendition of an out-of-P3 colour must keep its luminance");
  const auto hue=[](const std::array<float,3>& rgb) {
    const auto lab=linear_p3_to_oklab(rgb[0],rgb[1],rgb[2]);
    return std::atan2(lab[2],lab[1]);
  };
  require(std::abs(std::remainder(hue(hdr)-hue(green),6.2831853F))<3e-3F,
      "the HDR rendition of an out-of-P3 green must keep its Oklab hue");
  require(std::abs(hdr[0])>1e-3F || std::abs(hdr[2])>1e-3F,
      "an out-of-P3 green must not be clamped channel by channel");
}

int main() {
  try { test_zero_and_spatial_gain(); test_model_grading(); test_final_gain_statistics();
        test_hdr_source_reconstructs_itself(); test_hdr_source_outside_p3(); }
  catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
  std::cout<<"graded model reconstruction and final gain statistics passed\n";
}

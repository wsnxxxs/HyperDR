#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include <algorithm>
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
int main() {
  try { test_model_grading(); test_final_gain_statistics(); }
  catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
  std::cout<<"graded model reconstruction and final gain statistics passed\n";
}

#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/coding.hpp"
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
  // Exercise the normal Apple endpoint packager rather than the HDR-source
  // special case below.
  photo.hdr_is_source=false;
  const auto packed=gain_map_from_renditions(photo);
  const auto hdr=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
  float peak=1, difference=0;
  for(unsigned y=0;y<32;++y) for(unsigned x=0;x<64;++x) {
    const float alternate=p3_luminance(hdr.at(x,y,0),hdr.at(x,y,1),hdr.at(x,y,2));
    peak=std::max(peak,alternate);
    if(x<32) difference=std::max(difference,std::abs(alternate/.1F-1));
  }
  require(difference<1e-6F,"full-resolution packaging must not spill gain into dark pixels");
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
      const auto photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
      const auto packed=gain_map_from_renditions(photo);
      require(photo.sdr.pixels==packed.base_linear.pixels,"packaging must preserve the final base");
      const auto new_hdr=reconstruct_gain_map(packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
      for(std::size_t i=0;i<new_hdr.pixels.size();++i) {
        const float expected=photo.hdr.pixels[i];
        require(std::abs(expected-new_hdr.pixels[i])/std::max(expected,1e-3F)<.015F,
            "packaging must retain the final HDR endpoint within one gain-code step");
      }
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

  // Grading that gives the SDR endpoint its own colour is also derived from
  // the final endpoints without another spatial average.
  photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
  photo.hdr_is_source=false;
  const auto graded=gain_map_from_renditions(photo);
  require(graded.gain_map.width==source.width && graded.gain_map.height==source.height,
      "graded renditions must keep full-resolution endpoint gain");
}

void test_rendition_codes_use_serialized_metadata() {
  PhotoRenditions photo;
  photo.sdr=FloatImage(257,1,3);
  photo.hdr=FloatImage(257,1,3);
  photo.stats.headroom_stops=.1234564F;
  photo.stats.headroom_linear=std::exp2(photo.stats.headroom_stops);
  std::vector<float> intended(photo.sdr.width);
  for(std::uint32_t x=0;x<photo.sdr.width;++x) {
    const float gain=photo.stats.headroom_stops*static_cast<float>(x)/256.0F;
    for(unsigned c=0;c<3;++c) {
      photo.sdr.at(x,0,c)=.25F;
      photo.hdr.at(x,0,c)=.25F*std::exp2(gain);
    }
    intended[x]=std::log2(p3_luminance(photo.hdr.at(x,0,0),photo.hdr.at(x,0,1),photo.hdr.at(x,0,2))/.25F);
  }
  const float requested_max=*std::max_element(intended.begin(),intended.end());
  const auto packed=gain_map_from_renditions(photo);
  const float stored_max=rational_value(packed.metadata.gain_max);
  const float stored_gamma=rational_value(packed.metadata.gamma);
  bool exposes_old_float_path=false;
  for(std::uint32_t x=0;x<photo.sdr.width;++x) {
    const float stored_expected=quantize_gain_code_dithered(
        encode_gain_code(intended[x]/stored_max,stored_gamma),x,0);
    const float float_expected=quantize_gain_code_dithered(
        encode_gain_code(intended[x]/requested_max,stored_gamma),x,0);
    require(packed.gain_map.at(x,0,0)==stored_expected,
        "rendition codes must be quantized against serialized gain metadata");
    exposes_old_float_path|=stored_expected!=float_expected;
  }
  require(exposes_old_float_path,"quantization fixture did not distinguish float and serialized ranges");
  require(packed.headroom_stops==stored_max && packed.stats.gain_max_stops==stored_max,
      "runtime headroom must match serialized gain metadata");
}

void test_graded_sdr_endpoint_packaging() {
  FloatImage source(33,3,3);
  for(std::uint32_t y=0;y<source.height;++y) for(std::uint32_t x=0;x<source.width;++x) {
    const float v=.02F+.96F*static_cast<float>(x)/(source.width-1);
    source.at(x,y,0)=v;
    source.at(x,y,1)=v*(.75F+.1F*y);
    source.at(x,y,2)=v*.55F;
  }
  ColorLut lut;
  lut.size=2;
  lut.values={{.03F,.01F,.06F},{.72F,.94F,.81F}};
  ColorLutOptions grade{"endpoint-test.cube",LutSpace::Pq,LutSpace::Pq,.5F};
  RenderOptions options;
  options.auto_headroom=false;
  options.headroom_stops=2.0F;
  options.look.headroom_max_stops=2.0F;
  const auto graded=render_graded_photo(source,options,{},
      {InputDomain::kDisplayReferredSdr,1.0F},RenderTarget::Hdr,grade,&lut);
  const auto packed=gain_map_from_renditions(graded,GainMapWriterProfile::iso_generic);
  const auto reconstructed=reconstruct_gain_map(
      packed.base_linear,packed.gain_map,packed.metadata,packed.headroom_stops);
  require(packed.base_linear.pixels==graded.sdr.pixels,
      "packaging must retain the graded SDR endpoint");
  for(std::size_t i=0;i<reconstructed.pixels.size();++i) {
    require(std::abs(reconstructed.pixels[i]-graded.hdr.pixels[i])<.01F,
        "packaging must derive gain from the graded HDR endpoint");
  }
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

void test_independent_rgb_renditions() {
  PhotoRenditions photo;
  photo.sdr = FloatImage(5, 3, 3);
  photo.hdr = FloatImage(5, 3, 3);
  photo.stats.headroom_stops = 2;
  photo.stats.headroom_linear = 4;
  for (unsigned y = 0; y < 3; ++y) for (unsigned x = 0; x < 5; ++x) {
    const std::array<float, 3> base{.5F, .4F, .2F};
    const std::array<float, 3> hdr{x % 2 ? .25F : 2.0F, .8F, .05F};
    for (unsigned c = 0; c < 3; ++c) {
      photo.sdr.at(x, y, c) = base[c];
      photo.hdr.at(x, y, c) = hdr[c];
    }
  }
  // A graded channel can reach black at either endpoint.
  photo.sdr.at(4, 2, 0) = 0;
  photo.hdr.at(4, 2, 0) = .5F;
  photo.hdr.at(4, 2, 1) = 0;
  const auto packed = gain_map_from_renditions(photo, GainMapWriterProfile::iso_generic);
  require(packed.base_linear.pixels == photo.sdr.pixels, "RGB packaging must preserve the graded SDR endpoint");
  require(packed.gain_map.channels == 3 && packed.gain_map.width == 5 && packed.gain_map.height == 3,
      "independent endpoints need full-resolution RGB gain");
  require(rational_value(packed.metadata.gain_min) < 0, "RGB packaging must retain negative gains");
  require(packed.headroom_stops == rational_value(packed.metadata.gain_max) &&
      packed.headroom_stops > 4,
      "the declared range must include the actual maximum gain");
  require(packed.stats.gain_clipped_fraction == 0,
      "a channel ratio above display headroom is not clipped content");
  const auto metadata = parse_tmap_payload(serialize_tmap_payload(packed.metadata));
  require(gain_map_channel_count(metadata) == 3, "RGB metadata must survive serialization");
  const auto actual = reconstruct_gain_map(packed.base_linear, packed.gain_map, metadata, packed.headroom_stops);
  const auto halfway = reconstruct_gain_map(packed.base_linear, packed.gain_map, metadata, packed.headroom_stops*.5F);
  const auto sdr = reconstruct_gain_map(packed.base_linear, packed.gain_map, metadata, 0);
  const float offset = rational_value(metadata.channels[0].base_offset);
  double squared_error = 0;
  for (std::size_t i = 0; i < actual.pixels.size(); ++i) {
    const float expected = photo.hdr.pixels[i];
    require(std::abs(actual.pixels[i] - expected) < .035F * std::max(expected, .1F),
        "signed RGB gain must reconstruct each independently graded channel");
    const float middle = std::sqrt((photo.sdr.pixels[i] + offset) * (expected + offset)) - offset;
    require(std::abs(halfway.pixels[i] - middle) < .025F * std::max(middle, .1F),
        "intermediate display capacity must use the independent headroom");
    require(std::abs(sdr.pixels[i] - photo.sdr.pixels[i]) < 1e-6F, "SDR display must retain the base");
    squared_error += std::pow(actual.pixels[i] - expected, 2);
  }
  const auto compatible = gain_map_from_renditions(photo);
  validate_gain_map_metadata(compatible.metadata, GainMapWriterProfile::apple_strict);
  const auto old = reconstruct_gain_map(compatible.base_linear, compatible.gain_map,
      compatible.metadata, compatible.headroom_stops);
  double old_squared_error = 0;
  for (std::size_t i = 0; i < old.pixels.size(); ++i)
    old_squared_error += std::pow(old.pixels[i] - photo.hdr.pixels[i], 2);
  require(squared_error < old_squared_error * .01F,
      "RGB gain must materially reduce the single-channel color reconstruction error");
  std::cout << "Independent RGB rendition MSE: " << squared_error / actual.pixels.size()
            << " (single-channel: " << old_squared_error / actual.pixels.size() << ")\n";
}

void test_scene_base_without_gain_preparation() {
  FloatImage source(64,32,3);
  for (unsigned y=0;y<source.height;++y) for (unsigned x=0;x<source.width;++x)
    for (unsigned c=0;c<3;++c) source.at(x,y,c)=.005F+x*x*.002F+(2-c)*.02F;
  const InputDescription input{InputDomain::kSceneReferred,1};
  for (bool automatic : {false,true}) {
    RenderOptions options;
    options.auto_exposure=automatic;
    options.exposure_ev=-.5F;
    options.look.pop=0;
    const auto reference=render_renditions(source,options,{},input,RenderTarget::Hdr);
    GainMapPreparation prepared;
    const auto analysis=analyze_photographic_source(source);
    const auto sdr=render_renditions(source,options,{},input,RenderTarget::Sdr,&analysis,&prepared);
    require(sdr.sdr.pixels==reference.sdr.pixels,"SDR fast path must retain the HDR renderer's base pixels");
    require(!prepared.ready && prepared.stops.empty(),"SDR without local enhancement must not prepare HDR gain");
    options.gain_strength=0;
    const auto zero=render_renditions(source,options,{},input,RenderTarget::Hdr,&analysis,&prepared);
    require(zero.sdr.pixels==reference.sdr.pixels && zero.hdr.pixels==zero.sdr.pixels,
        "zero gain must preserve the base and produce identical endpoints");
    require(!prepared.ready,"zero gain without local enhancement must not prepare a gain grid");
    options.gain_strength=1;
    const auto restored=render_renditions(source,options,{},input,RenderTarget::Hdr,&analysis,&prepared);
    require(prepared.ready && restored.hdr.pixels==reference.hdr.pixels,
        "enabling gain after the fast path must prepare the correct HDR pixels");
    options.gain_strength=0;
    const auto cached_zero=render_renditions(source,options,{},input,RenderTarget::Hdr,&analysis,&prepared);
    require(cached_zero.hdr.pixels==zero.hdr.pixels,"a warm gain cache must not change the zero-gain frame");
  }
}

void test_content_light_mapping() {
  for (float peak : {1.0F, 4.0F}) {
    FloatImage source(32, 8, 3);
    for (unsigned y=0;y<source.height;++y) for (unsigned x=0;x<source.width;++x)
      for (unsigned c=0;c<3;++c) source.at(x,y,c)=peak*x/(source.width-1);
    InputDescription input{InputDomain::kDisplayReferredHdr, 10000.0F/kReferenceWhiteNits};
    input.content_peak_nits=peak*kReferenceWhiteNits;
    RenderOptions options;
    const auto photo=render_renditions(source,options,{},input,RenderTarget::Hdr);
    require(std::abs(photo.stats.headroom_stops-std::log2(peak))<1e-5F,
        "HDR output range must use content light, not PQ capacity");
    for (std::size_t i=0;i<source.pixels.size();++i)
      require(std::abs(photo.hdr.pixels[i]-source.pixels[i])<1e-5F,
          "content fitting the output must not receive another HDR shoulder");
    const auto sdr=render_renditions(source,options,{},input,RenderTarget::Sdr);
    require(sdr.sdr.pixels==photo.sdr.pixels,"content light must agree in SDR-only and paired rendering");
    if (peak==1) {
      const auto legacy=make_gain_map(source,{}, {},input);
      require(legacy.headroom_stops==0,"SDR-range PQ must not be creatively expanded");
      for(std::size_t i=0;i<source.pixels.size();++i)
        require(std::abs(legacy.base_linear.pixels[i]-source.pixels[i])<1e-5F,
            "legacy gain-map rendering must retain SDR-range PQ light");
    } else {
      const auto expected=render_renditions(source,options,{},
          {InputDomain::kDisplayReferredHdr,peak},RenderTarget::Hdr);
      require(photo.sdr.pixels==expected.sdr.pixels,"MaxCLL must set the same SDR shoulder as declared content range");
    }
    input.content_peak_nits=20000.0F;
    require(rendering_headroom(input)==input.headroom,"content hint cannot expand transfer capacity");
    input.content_peak_nits.reset();
    require(rendering_headroom(input)==input.headroom,"unknown content must retain the encoding fallback");
  }
}

void test_authored_dual_renditions() {
  FloatImage base(4,1,3), hdr(4,1,3);
  const std::array<float,4> levels{.2F,.4F,.7F,.9F};
  const std::array<float,4> gains{1,2,3,4};
  for (unsigned x=0;x<4;++x) for (unsigned c=0;c<3;++c) {
    base.at(x,0,c)=levels[x];
    hdr.at(x,0,c)=levels[x]*gains[x];
  }
  InputDescription input{InputDomain::kDualRendition,4};
  input.authored_sdr=&base;
  input.gain_map.alternate_headroom=4;
  RenderOptions options;
  const auto photo=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
  require(photo.sdr.pixels==base.pixels && photo.hdr.pixels==hdr.pixels,
      "neutral dual rendering must retain both authored endpoints");
  const auto rgb=gain_map_from_renditions(photo,GainMapWriterProfile::iso_generic);
  require(rgb.base_linear.pixels==base.pixels && rgb.gain_map.channels==3,
      "Ultra HDR must retain the authored base and use RGB gain");
  const auto restored=reconstruct_gain_map(rgb.base_linear,rgb.gain_map,rgb.metadata,rgb.headroom_stops);
  for (std::size_t i=0;i<hdr.pixels.size();++i)
    require(std::abs(restored.pixels[i]-hdr.pixels[i])<.02F,
        "Ultra HDR must reconstruct the authored HDR rendition");
  const auto apple=gain_map_from_renditions(photo,GainMapWriterProfile::apple_strict);
  require(apple.base_linear.pixels==base.pixels && !apple.stats.adaptive_chroma_loss,
      "monochrome Adaptive must retain the authored base");
  input.gain_map.channels=3;
  hdr.at(2,0,0)=.7F*3.5F;
  const auto chromatic=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
  const auto adaptive=gain_map_from_renditions(chromatic,GainMapWriterProfile::apple_strict);
  require(adaptive.stats.adaptive_chroma_loss,
      "three-channel Adaptive conversion must report SDR chroma loss");
  input.gain_map.channels=1;
  hdr.at(2,0,0)=.7F*3;
  options.gain_strength=.5F;
  const auto half=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
  for (unsigned c=0;c<3;++c)
    require(half.hdr.at(0,0,c)==base.at(0,0,c),
        "zero-gain midtones must remain fixed at half strength");
  options.gain_strength=0;
  const auto zero=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
  require(zero.hdr.pixels==base.pixels,"zero strength must equal the authored base");
}

void test_dual_nonunit_base_headroom() {
  FloatImage base(1,1,3), hdr(1,1,3);
  base.pixels={.5F,.5F,.5F}; hdr.pixels={2,2,2};
  InputDescription input{InputDomain::kDualRendition,8};
  input.authored_sdr=&base;
  input.gain_map.base_headroom=2;
  input.gain_map.alternate_headroom=8;
  RenderOptions options;
  options.auto_headroom=false;
  options.headroom_stops=2;
  options.gain_strength=1;
  const auto result=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
  require(std::abs(result.hdr.pixels[0]-1)<1e-5F &&
      std::abs(result.stats.headroom_stops-2)<1e-5F,
      "display headroom must be measured from the authored base headroom");
}

void test_dual_metadata_range_and_edited_mono() {
  FloatImage base(2,1,3), hdr(2,1,3);
  base.pixels={.2F,.4F,.6F,.25F,.35F,.45F};
  for (std::size_t i=0;i<base.pixels.size();++i)
    hdr.pixels[i]=2*base.pixels[i]+.1F;
  InputDescription input{InputDomain::kDualRendition,2};
  input.authored_sdr=&base;
  input.gain_map.alternate_headroom=16;
  input.gain_map.base_offset.fill(.1F);
  input.gain_map.alternate_offset.fill(.1F);
  // The metadata can describe more range than this frame uses. A neutral
  // four-stop budget still reaches the authored alternate endpoint.
  const auto neutral=render_renditions(hdr,{}, {},input,RenderTarget::Hdr);
  require(neutral.hdr.pixels==hdr.pixels && neutral.sdr.pixels==base.pixels,
      "measured pixel peak must not shorten the authored interpolation span");
  const auto compatible=gain_map_from_renditions(neutral,GainMapWriterProfile::apple_strict);
  require(compatible.base_linear.pixels==base.pixels && !compatible.stats.adaptive_chroma_loss,
      "an unedited mono gain with offsets must preserve the authored SDR base");
  RenderOptions brighter;
  brighter.exposure_bias_ev=1;
  const auto edited=render_renditions(hdr,brighter,{},input,RenderTarget::Hdr);
  const auto fallback=gain_map_from_renditions(edited,GainMapWriterProfile::apple_strict);
  require(fallback.stats.adaptive_chroma_loss,
      "exposure that breaks common gain must report Adaptive SDR chroma loss");
  const auto reconstructed=reconstruct_gain_map(fallback.base_linear,fallback.gain_map,
      fallback.metadata,fallback.headroom_stops);
  for (std::size_t i=0;i<hdr.pixels.size();++i)
    require(std::abs(reconstructed.pixels[i]-edited.hdr.pixels[i])<.015F,
        "the Apple fallback must prioritize the edited HDR endpoint");
  brighter.gain_strength=0;
  const auto zero=render_renditions(hdr,brighter,{},input,RenderTarget::Hdr);
  brighter.gain_strength=1e-5F;
  const auto near_zero=render_renditions(hdr,brighter,{},input,RenderTarget::Hdr);
  for (std::size_t i=0;i<hdr.pixels.size();++i)
    require(std::abs(near_zero.hdr.pixels[i]-zero.sdr.pixels[i])<1e-4F,
        "positive-exposure SDR rolloff must meet zero HDR strength continuously");
}

void test_dual_signed_rgb_gain() {
  FloatImage base(1,1,3), hdr(1,1,3);
  base.pixels={.5F,.5F,.5F}; hdr.pixels={.25F,1.0F,.5F};
  InputDescription input{InputDomain::kDualRendition,2};
  input.authored_sdr=&base;
  input.gain_map.channels=3;
  input.gain_map.alternate_headroom=2;
  const auto photo=render_renditions(hdr,{}, {},input,RenderTarget::Hdr);
  const auto packed=gain_map_from_renditions(photo,GainMapWriterProfile::iso_generic);
  require(rational_value(packed.metadata.gain_min)<0 &&
      packed.base_linear.pixels==base.pixels,
      "signed RGB gain must preserve darkened channels and the authored base");
  const auto reconstructed=reconstruct_gain_map(packed.base_linear,packed.gain_map,
      packed.metadata,packed.headroom_stops);
  for (unsigned c=0;c<3;++c)
    require(std::abs(reconstructed.pixels[c]-hdr.pixels[c])<.01F,
        "signed RGB gain must reconstruct the authored alternate");
}

void test_single_hdr_midtones_at_half_strength() {
  FloatImage hdr(3,1,3);
  for (unsigned c=0;c<3;++c) {
    hdr.at(0,0,c)=.5F; hdr.at(1,0,c)=1; hdr.at(2,0,c)=4;
  }
  RenderOptions options;
  options.gain_strength=.5F;
  const auto result=render_renditions(hdr,options,{},
      {InputDomain::kDisplayReferredHdr,4},RenderTarget::Hdr);
  for (unsigned c=0;c<3;++c)
    require(std::abs(result.hdr.at(1,0,c)-1)<1e-5F,
        "half strength must keep HDR diffuse white at 1");
}

int main() {
  try { test_zero_and_spatial_gain(); test_model_grading(); test_final_gain_statistics();
        test_hdr_source_reconstructs_itself(); test_hdr_source_outside_p3();
        test_independent_rgb_renditions(); test_scene_base_without_gain_preparation();
        test_rendition_codes_use_serialized_metadata();
        test_graded_sdr_endpoint_packaging();
        test_content_light_mapping(); test_authored_dual_renditions();
        test_dual_nonunit_base_headroom(); test_single_hdr_midtones_at_half_strength();
        test_dual_metadata_range_and_edited_mono(); test_dual_signed_rgb_gain(); }
  catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
  std::cout<<"graded model reconstruction and final gain statistics passed\n";
}

#include "hyperdr/look/color_lut.hpp"
#include "hyperdr/image/transfer.hpp"
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
using namespace hyperdr;
void require(bool ok, const char* message) { if(!ok) throw std::runtime_error(message); }

void require_image_close(const FloatImage& actual, const FloatImage& expected,
    const char* message) {
  require(actual.pixels.size()==expected.pixels.size(),message);
  for(std::size_t i=0;i<actual.pixels.size();++i)
    require(std::abs(actual.pixels[i]-expected.pixels[i])<5e-4F,message);
}

void test_hdr_strength_continuity(const ColorLut& lut,
    const std::filesystem::path& file) {
  // SDR gamut fitting and HDR highlights can have different chromaticities.
  PhotoRenditions original;
  original.sdr=FloatImage(1,1,3); original.sdr.pixels={.8F,.7F,.5F};
  original.hdr=FloatImage(1,1,3); original.hdr.pixels={3.8F,.8F,.2F};
  original.stats.headroom_stops=2; original.stats.headroom_linear=4;
  ColorLutOptions grade{file,LutSpace::Srgb,LutSpace::Srgb,1};
  auto full=original;
  apply_rendition_lut(full,grade,&lut);
  for(float strength:{0.0F,1e-5F,.25F,.5F,1.0F}) {
    grade.strength=strength;
    auto partial=original;
    apply_rendition_lut(partial,grade,&lut);
    for(int c=0;c<3;++c) {
      require(std::abs(partial.sdr.pixels[c]-std::lerp(original.sdr.pixels[c],full.sdr.pixels[c],strength))<1e-6F,
          "SDR LUT strength must blend its endpoints in linear light");
      require(std::abs(partial.hdr.pixels[c]-std::lerp(original.hdr.pixels[c],full.hdr.pixels[c],strength))<1e-6F,
          "HDR LUT strength must blend from the original HDR colour without a jump");
    }
  }
}

ColorLut hdr_conversion_lut(LutSpace input, LutSpace output, float scale=1) {
  ColorLut lut;
  lut.size=4096;
  for(unsigned i=0;i<lut.size;++i) {
    const float code=static_cast<float>(i)/(lut.size-1);
    const float linear=input==LutSpace::Hlg?hlg_inverse_oetf(code):pq_eotf(code);
    const float mapped=output==LutSpace::Hlg?hlg_oetf(linear*scale):pq_oetf(linear*scale);
    lut.values.push_back({mapped,mapped,mapped});
  }
  return lut;
}

void test_hdr_lut_headroom(const std::filesystem::path& file) {
  FloatImage source(8,1,3);
  for(unsigned x=0;x<source.width;++x) {
    const float y=.02F+.35F*x;
    source.at(x,0,0)=y; source.at(x,0,1)=y*.8F; source.at(x,0,2)=y*.6F;
  }
  // A saturated highlight can exceed the P3 channel limit while its luminance
  // remains below the declared 4x range, as in real BT.2020 HIF input.
  source.at(7,0,0)=5; source.at(7,0,1)=2; source.at(7,0,2)=.5F;
  // The declared 4x range deliberately exceeds the brightest actual luminance.
  const InputDescription input{InputDomain::kDisplayReferredHdr,4};
  ColorLut identity; identity.size=2; identity.values={{0,0,0},{1,1,1}};
  RenderOptions options; options.auto_headroom=false; options.headroom_stops=3;
  for(auto space:{LutSpace::Hlg,LutSpace::Pq}) {
    ColorLutOptions grade{file,space,space,1};
    for(float strength:{1.0F,.4F}) for(float exposure:{0.0F,.2F}) {
      options.gain_strength=strength; options.exposure_bias_ev=exposure;
      const auto expected=render_renditions(source,options,{},input,RenderTarget::Hdr);
      const auto actual=render_graded_photo(source,options,{},input,RenderTarget::Hdr,grade,&identity);
      require_image_close(actual.hdr,expected.hdr,"identity HDR LUT must preserve HDR highlights and apply exposure/strength once");
      require_image_close(actual.sdr,expected.sdr,"identity HDR LUT must preserve SDR tone mapping from declared headroom");
      require(std::abs(actual.stats.headroom_stops-expected.stats.headroom_stops)<1e-4F,
          "HDR LUT headroom must not become the encoding's theoretical maximum");
      const auto sdr=render_graded_photo(source,options,{},input,RenderTarget::Sdr,grade,&identity);
      require_image_close(sdr.sdr,expected.sdr,"SDR-only must share the corrected HDR LUT mapping");
    }
  }
  options.gain_strength=1; options.exposure_bias_ev=0;
  ColorLutOptions grade{file,LutSpace::Hlg,LutSpace::Pq,1};
  const auto conversion=hdr_conversion_lut(grade.input,grade.output);
  const auto converted=render_graded_photo(source,options,{},input,RenderTarget::Hdr,grade,&conversion);
  const auto expected=render_renditions(source,options,{},input,RenderTarget::Hdr);
  require_image_close(converted.hdr,expected.hdr,"HLG to PQ conversion must not assign a 10000-nit photo range");
  require_image_close(converted.sdr,expected.sdr,"HLG to PQ conversion must preserve SDR tone mapping");
  const auto dimmer=hdr_conversion_lut(grade.input,grade.output,.5F);
  auto scaled=source; for(auto& c:scaled.pixels)c*=.5F;
  const auto dimmed=render_graded_photo(source,options,{},input,RenderTarget::Hdr,grade,&dimmer);
  const auto dimmed_expected=render_renditions(scaled,options,{},
      {InputDomain::kDisplayReferredHdr,2},RenderTarget::Hdr);
  require_image_close(dimmed.sdr,dimmed_expected.sdr,"a LUT that lowers the photo range must lower its mapping headroom too");
  for(float strength:{1e-5F,.5F}) {
    grade.strength=strength;
    const auto partial=render_graded_photo(source,options,{},input,RenderTarget::Hdr,grade,&dimmer);
    require(std::abs(partial.stats.headroom_linear-std::lerp(4.0F,2.0F,strength))<5e-4F,
        "partial HDR LUT strength must blend headroom with its pixels");
    for(std::size_t i=0;i<partial.hdr.pixels.size();++i)
      require(std::abs(partial.hdr.pixels[i]-std::lerp(expected.hdr.pixels[i],dimmed.hdr.pixels[i],strength))<1e-6F,
          "HDR LUT highlight compression must also vary continuously with strength");
  }

  options.gain_strength=.4F;
  grade.strength=1;
  grade.input=grade.output=LutSpace::Hlg;
  for(auto domain:{InputDomain::kSceneReferred,InputDomain::kDisplayReferredSdr}) {
    const InputDescription developed_input{domain,1};
    const auto baseline=render_renditions(source,options,{},developed_input,RenderTarget::Hdr);
    const auto graded=render_graded_photo(source,options,{},developed_input,RenderTarget::Hdr,grade,&identity);
    require_image_close(graded.hdr,baseline.hdr,"an already-developed HDR rendition must not apply HDR strength twice");
  }
}

void test_hdr_lut_below_reference_white(const std::filesystem::path& file) {
  FloatImage source(4,1,3);
  for(unsigned x=0;x<source.width;++x)
    for(int c=0;c<3;++c) source.at(x,0,c)=.1F+x;
  RenderOptions options;
  for(auto space:{LutSpace::Hlg,LutSpace::Pq}) for(float level:{0.0F,.5F,1.0F}) {
    const auto code=encode_lut_space({level,level,level},space);
    ColorLut lut; lut.size=2; lut.values={code,code};
    ColorLutOptions grade{file,space,space,1};
    for(auto target:{RenderTarget::Sdr,RenderTarget::Hdr}) {
      const auto result=render_graded_photo(source,options,{},
          {InputDomain::kDisplayReferredHdr,4},target,grade,&lut);
      require(result.stats.headroom_stops<1e-4F,
          "an HDR LUT ending below reference white must not invent HDR expansion");
      for(float c:result.sdr.pixels)
        require(std::abs(c-level)<5e-4F,"sub-white HDR LUT output must remain valid SDR");
      for(float c:result.hdr.pixels)
        require(std::abs(c-level)<5e-4F,"an HDR container must preserve a sub-white LUT result");
    }
  }
}

void test_sdr_hdr_lut_routing(const std::filesystem::path& file) {
  FloatImage source(16,8,3);
  for(unsigned y=0;y<source.height;++y) for(unsigned x=0;x<source.width;++x) {
    const float v=.01F+static_cast<float>(x*x)/(source.width*source.width);
    source.at(x,y,0)=v; source.at(x,y,1)=v*.8F; source.at(x,y,2)=v*.6F;
  }
  source.at(15,0,0)=.85F; source.at(15,0,1)=.995F; source.at(15,0,2)=.16F;
  for(int c=0;c<3;++c) source.at(15,1,c)=1;
  ColorLut identity; identity.size=2; identity.values={{0,0,0},{1,1,1}};
  for(auto domain:{InputDomain::kSceneReferred,InputDomain::kDisplayReferredSdr}) {
    const InputDescription input{domain,1};
    RenderOptions options;
    const auto baseline=render_renditions(source,options,{},input,RenderTarget::Sdr);
    for(auto space:{LutSpace::Hlg,LutSpace::Pq}) {
      ColorLutOptions grade{file,space,space,1};
      const auto dimmer=hdr_conversion_lut(space,space,.5F);
      for(bool alternate:{false,true}) {
        auto selected=options;
        if(alternate) {
          selected.auto_headroom=false; selected.headroom_stops=1;
          selected.look.headroom_max_stops=1; selected.gain_strength=0;
          selected.look.shoulder_start=.75F; selected.look.diffuse_gain_floor=0;
        }
        const auto ungraded=render_renditions(source,selected,{},input,RenderTarget::Sdr);
        require_image_close(ungraded.sdr,baseline.sdr,"hidden HDR controls must not affect SDR development or RAW auto exposure");
        const auto result=render_graded_photo(source,selected,{},input,RenderTarget::Sdr,grade,&identity);
        require_image_close(result.sdr,baseline.sdr,"identity HLG/PQ LUT must preserve RAW/SDR output without an HDR round trip");
        require(result.hdr.pixels.empty() && result.stats.headroom_stops==0,"SDR HDR-LUT routing must remain SDR-only");
        const auto dimmed=render_graded_photo(source,selected,{},input,RenderTarget::Sdr,grade,&dimmer);
        auto expected=baseline.sdr; for(auto& c:expected.pixels) c*=.5F;
        require_image_close(dimmed.sdr,expected,"a real HLG/PQ LUT must still grade SDR without hidden HDR controls");
      }
    }
  }
}

void test_near_unit_headroom() {
  // PQ round trips can put nominal SDR white just above 1. Such a tiny
  // range must not cause visible changes through unstable shoulder arithmetic.
  FloatImage ramp(64,1,3);
  for(unsigned x=0;x<ramp.width;++x)
    for(int c=0;c<3;++c) ramp.at(x,0,c)=static_cast<float>(x)/(ramp.width-1);
  const auto result=render_renditions(ramp,{}, {},
      {InputDomain::kDisplayReferredHdr,1.00005F},RenderTarget::Sdr);
  for(std::size_t i=0;i<ramp.pixels.size();++i)
    require(std::abs(result.sdr.pixels[i]-ramp.pixels[i])<1e-4F,
        "near-unit headroom must approach SDR passthrough smoothly");
}

int main() {
  const auto file=std::filesystem::temp_directory_path()/"hyperdr-color-lut-test.cube";
  try {
    {
      std::ofstream out(file);
      out << "# red-fastest, swap red/blue and halve green\nTITLE \"Test\"\nLUT_3D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n";
      for(int b=0;b<2;++b) for(int g=0;g<2;++g) for(int r=0;r<2;++r) out<<b<<' '<<g*.5F<<' '<<r<<'\n';
    }
    auto lut=read_color_lut(file);
    auto rgb=lut.sample({-.5F,0,.5F});
    require(std::abs(rgb[0]-.75F)<1e-6F && std::abs(rgb[1]-.25F)<1e-6F && std::abs(rgb[2]-.25F)<1e-6F,"cube ordering/domain/interpolation");
    require(lut.sample({-4,0,4})[0]==1,"cube domain must clamp");
    { std::ofstream out(file); out<<"LUT_1D_SIZE 2\n0 0 0\n1 .5 1\n"; }
    lut=read_color_lut(file);
    require(std::abs(lut.sample({.3F,.8F,.4F})[1]-.4F)<1e-6F,"1D channels must be independent");
    for(auto space:{LutSpace::Srgb,LutSpace::DisplayP3,LutSpace::Rec709,LutSpace::Hlg,LutSpace::Pq,LutSpace::SLog3}) {
      const std::array<float,3> source{.2F,.3F,.4F};
      const auto decoded=decode_lut_space(encode_lut_space(source,space),space);
      for(int c=0;c<3;++c) require(std::abs(source[c]-decoded[c])<3e-5F,"LUT space round trip");
    }
    require(std::abs(encode_lut_space({.18F,.18F,.18F},LutSpace::SLog3)[0]-420.0F/1023)<1e-6F,"Sony S-Log3 middle grey anchor");
    FloatImage hdr(64,64,3);
    for(auto& c:hdr.pixels)c=.18F;
    for(int c=0;c<3;++c)hdr.at(32,32,c)=4;
    RenderOptions options;
    options.auto_headroom=false; options.headroom_stops=3;
    const InputDescription input{InputDomain::kDisplayReferredHdr,1000.0F/203};
    const auto direct=render_renditions(hdr,options,{},input,RenderTarget::Hdr);
    require(std::abs(direct.hdr.at(32,32,0)-4)<1e-5F,"direct HDR must retain isolated source highlights");
    const auto sdr=render_renditions(hdr,options,{},input,RenderTarget::Sdr);
    require(sdr.hdr.pixels.empty() && sdr.stats.headroom_stops==0,"SDR-only must not allocate an HDR rendition");
    require(sdr.sdr.pixels==direct.sdr.pixels,"SDR development must not depend on output format");
    for(auto c:sdr.sdr.pixels)require(c>=0 && c<=1,"HDR to SDR must fit its range");
    ColorLutOptions grade{file,LutSpace::Srgb,LutSpace::Srgb,0};
    require(render_graded_photo(hdr,options,{},input,RenderTarget::Hdr,grade).hdr.pixels==direct.hdr.pixels,"zero strength must bypass colour transforms exactly");
    grade.strength=1;
    const auto graded=render_graded_photo(hdr,options,{},input,RenderTarget::Sdr,grade);
    require(graded.sdr.at(1,1,1)<sdr.sdr.at(1,1,1)*.5F,"SDR LUT must grade HDR sources");
    grade.input=LutSpace::SLog3; grade.output=LutSpace::Rec709;
    const auto raw=render_graded_photo(hdr,options,{},InputDescription{},RenderTarget::Sdr,grade);
    require(raw.hdr.pixels.empty(),"RAW Log LUT supports SDR-only");
    bool rejected=false;
    try { (void)render_graded_photo(hdr,options,{},input,RenderTarget::Sdr,grade); }
    catch(const std::invalid_argument&) {rejected=true;}
    require(rejected,"finished HLG/PQ is not camera Log");
    test_hdr_strength_continuity(lut,file);
    test_hdr_lut_headroom(file);
    test_hdr_lut_below_reference_white(file);
    test_sdr_hdr_lut_routing(file);
    test_near_unit_headroom();
    {std::ofstream out(file);out<<"LUT_3D_SIZE 2\n0 0 0\n";}
    rejected=false;
    try{(void)read_color_lut(file);}catch(const std::invalid_argument&){rejected=true;}
    require(rejected,"incomplete LUT must be rejected");
    std::filesystem::remove(file);
    std::cout<<"colour LUT and rendition tests passed\n";
  } catch(const std::exception& e) {std::filesystem::remove(file);std::cerr<<e.what()<<'\n';return 1;}
}

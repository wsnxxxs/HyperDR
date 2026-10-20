#include "hyperdr/app/package.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "../support/temp_directory.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
using namespace hyperdr;
static void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
int main() try {
  const auto directory=test::temporary_directory();
  constexpr unsigned w=128,h=96,pad=32,cw=w+pad*2,ch=h+pad*2;
  for(const auto encoding:{OutputEncoding::IsoGainMapJpeg,OutputEncoding::Adaptive,OutputEncoding::Pq,OutputEncoding::Hlg,OutputEncoding::AvifPq,OutputEncoding::AvifHlg}){
    for(int depth:{8,10}){
      if(depth==10&&encoding!=OutputEncoding::Adaptive)continue;
      FloatImage base(w,h,3),gain(w,h,1),card(cw,ch,3),card_gain(cw,ch,1);
      std::fill(card.pixels.begin(),card.pixels.end(),1.F);
      for(unsigned y=0;y<h;++y)for(unsigned x=0;x<w;++x){
        const float value=.05F+.7F*float(x)/(w-1);
        // Smooth tones, a highlight block and a signed ISO edge exercise E5's codebook.
        const float stops=(encoding==OutputEncoding::IsoGainMapJpeg&&x<32)?-.25F:(x>80&&y>32?2.F:float(x)/w);
        gain.at(x,y,0)=card_gain.at(x+pad,y+pad,0)=stops;
        for(unsigned c=0;c<3;++c)base.at(x,y,c)=card.at(x+pad,y+pad,c)=value*(1.F-.1F*c);
      }
      auto write=[&](const FloatImage& b,const FloatImage& g,const std::filesystem::path& path,bool frame){
        PackagePlane plane{b.pixels.data(),0,b.pixels.size()*sizeof(float),b.width,b.height,3};
        PackageGain auxiliary;auxiliary.plane={g.pixels.data(),0,g.pixels.size()*sizeof(float),g.width,g.height,1};auxiliary.alternate_headroom=2;
        PackageRequest request;request.output=path;request.encoding=encoding;request.quality=90;request.depth=depth;request.sdr=&plane;request.gain=&auxiliary;request.presentation_frame=true;
        if(frame&&is_gain_map_encoding(encoding))request.frame_photo=FrameRect{pad,pad,w,h};
        // package performs its exact-zero codebook test and bounded mat readback before publishing.
        (void)package_image(request);
      };
      const auto plain=directory/"plain",framed=directory/"frame";
      write(base,gain,plain,false);write(card,card_gain,framed,true);
      const auto reference=decode_image(plain).linear_p3,candidate=decode_image(framed).linear_p3;
      require(candidate.width==cw&&candidate.height==ch,"E5 framed dimensions");
      if(!is_gain_map_encoding(encoding)){
        FloatImage mat((cw*ch-w*h),1,3),white((cw*ch-w*h),1,3);
        std::fill(white.pixels.begin(),white.pixels.end(),1.F);
        unsigned offset=0;
        for(unsigned y=0;y<ch;++y)for(unsigned x=0;x<cw;++x){
          const int distance=std::max({int(pad)-int(x),int(x)-int(pad+w-1),int(pad)-int(y),int(y)-int(pad+h-1)});
          if(distance<=3)continue; // Same excluded photo-edge ring as the frozen E5 gate.
          for(unsigned c=0;c<3;++c)mat.pixels[offset++]=candidate.at(x,y,c);
        }
        mat.pixels.resize(offset);white.pixels.resize(offset);mat.width=white.width=offset/3;
        const auto fidelity=measure_hdr_fidelity(white,mat);
        require(fidelity.delta_e_itp_p99<=3 && fidelity.candidate_mean>=.98 && fidelity.candidate_mean<=1.02,"E5 SDR mat colour/white regressed");
      }
      double total=0,peak_a=0,peak_b=0;unsigned count=0;
      constexpr unsigned k=3;
      for(unsigned y=k;y<h-k;++y)for(unsigned x=k;x<w-k;++x){
        const auto a=p3_luminance(reference.at(x,y,0),reference.at(x,y,1),reference.at(x,y,2));
        const auto b=p3_luminance(candidate.at(x+pad,y+pad,0),candidate.at(x+pad,y+pad,1),candidate.at(x+pad,y+pad,2));
        total+=std::abs(std::log2(std::max(a,1e-6F)/std::max(b,1e-6F)));++count;peak_a=std::max(peak_a,double(a));peak_b=std::max(peak_b,double(b));
      }
      const double mean=total/count,peak=std::abs(peak_b/peak_a-1);
      require(mean<=.02 && peak<=.01,"E5 photo preservation regressed");
      std::cout<<json::Writer().begin_object().member("format",hdr_encoding_name(encoding)).member("depth",depth).member("mean_abs_log2",mean).member("peak_relative_error",peak).end_object().take()<<'\n';
      std::filesystem::remove(plain);std::filesystem::remove(framed);
    }
  }
  return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}

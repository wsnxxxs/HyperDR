// A research comparison, not a production encoder or a claim of invention.
// Calls the actual HyperDR packager. All policies use the same 8-bit gain range.
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/foundation/rational.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using namespace hyperdr;

struct Fixture {
  std::string name;
  PhotoRenditions photo;
  float offset;
};
Fixture shared(std::string name, float low, float high, float offset, bool edit) {
  Fixture f{name, {}, offset};
  f.photo.sdr = FloatImage(256, 64, 3);
  f.photo.hdr = FloatImage(256, 64, 3);
  f.photo.dual_rendition = true;
  f.photo.authored_gain_map.base_offset.fill(offset);
  f.photo.authored_gain_map.alternate_offset.fill(offset);
  for (unsigned y=0; y<64; ++y) for (unsigned x=0; x<256; ++x) {
    const float stop = low + (high-low)*float(x)/255;
    const float mult = std::exp2(stop);
    const std::array<float,3> s{.12F+.75F*float(y%13)/12,
      .06F+.57F*float(y%7)/6, y%5==0 ? 0.0F : .18F};
    for (unsigned c=0;c<3;++c) {
      f.photo.sdr.at(x,y,c)=s[c];
      f.photo.hdr.at(x,y,c)=std::max(0.0F,(s[c]+offset)*mult-offset);
    }
    if (edit && (x+7*y)%32==0 && x>0 && x<255) {
      f.photo.hdr.at(x,y,0)*=1.18F;
      f.photo.hdr.at(x,y,1)*=.94F;
    }
  }
  return f;
}
Fixture resize_edges() {
  auto f = shared("independent_area_resize",0,4,0,false);
  for (unsigned y=0;y<64;++y) for(unsigned x=0;x<256;++x) {
    if (x<8 || x>247 || (x/8+y/4)%4!=0) continue;
    // Average two source pixels with different colours AND gains. Averaging
    // the two endpoints independently need not preserve one RGB multiplier.
    const std::array<float,3> a{.8F,.08F,.01F}, b{.02F,.65F,.3F};
    const float ma=std::exp2(4.0F*float(x)/255), mb=std::exp2(.5F);
    for(unsigned c=0;c<3;++c) {
      f.photo.sdr.at(x,y,c)=.5F*(a[c]+b[c]);
      f.photo.hdr.at(x,y,c)=.5F*(a[c]*ma+b[c]*mb);
    }
  }
  return f;
}
float gain_for(float sy,float hy,float off) {
  return sy+off>1e-12F && hy+off>1e-12F ? std::log2((hy+off)/(sy+off)) : 0;
}
std::vector<bool> repair_mask(const Fixture& f) {
  const auto n=f.photo.sdr.pixels.size()/3;
  std::vector<bool> mask(n,false);
  for(std::size_t p=0;p<n;++p) {
    const auto* s=&f.photo.sdr.pixels[p*3];const auto* h=&f.photo.hdr.pixels[p*3];
    const float g=gain_for(p3_luminance(s[0],s[1],s[2]),p3_luminance(h[0],h[1],h[2]),f.offset);
    const float m=std::exp2(g),peak=std::max({h[0],h[1],h[2],0.0F});
    for(unsigned c=0;c<3;++c)
      if(std::abs(std::max(0.0F,(s[c]+f.offset)*m-f.offset)-h[c])>1e-3F*peak+1e-5F)
        mask[p]=true;
  }
  return mask;
}
void emit(const Fixture& f,const std::string& policy,GainMapResult out,const std::vector<bool>& mask) {
  const auto rebuilt=reconstruct_gain_map(out.base_linear,out.gain_map,out.metadata,out.headroom_stops);
  const auto n=mask.size();std::size_t changed=0,any=0,over=0,repair=0;
  double mse_s=0,mse_h=0;float max_s=0,max_h=0;
  std::vector<float> relative;
  for(std::size_t p=0;p<n;++p) {
    float ds=0,dh=0,peak=0;
    for(unsigned c=0;c<3;++c) {
      const auto i=p*3+c;const float a=out.base_linear.pixels[i]-f.photo.sdr.pixels[i];
      const float b=rebuilt.pixels[i]-f.photo.hdr.pixels[i];
      ds=std::max(ds,std::abs(a));dh=std::max(dh,std::abs(b));
      peak=std::max(peak,f.photo.hdr.pixels[i]);mse_s+=a*a;mse_h+=b*b;
    }
    changed+=ds>1.0F/255;any+=ds>1e-7F;repair+=mask[p];
    over+=dh>1e-3F*peak+1e-5F;
    max_s=std::max(max_s,ds);max_h=std::max(max_h,dh);
    relative.push_back(dh/std::max(peak,1e-5F));
  }
  std::sort(relative.begin(),relative.end());
  auto pct=[n](std::size_t v){return 100.0*double(v)/double(n);};
  std::cout<<f.name<<','<<policy<<','<<n<<','<<pct(repair)<<','<<pct(any)<<','<<pct(changed)
    <<','<<max_s<<','<<mse_s/(n*3)<<','<<max_h<<','<<mse_h/(n*3)
    <<','<<100*relative[static_cast<std::size_t>(.99*(n-1))]<<','<<100*relative.back()
    <<','<<pct(over)<<','<<rational_value(out.metadata.gain_min)<<','<<rational_value(out.metadata.gain_max)<<'\n';
}
void run(const Fixture& f) {
  const auto production=gain_map_from_renditions(f.photo,GainMapWriterProfile::apple_strict);
  const auto mask=repair_mask(f);
  emit(f,"production_selective",production,mask);
  const float low=rational_value(production.metadata.gain_min),high=rational_value(production.metadata.gain_max);
  const float range=high-low;const auto n=mask.size();
  for(const std::string policy:{"preserve_all","inverse_all","selective_code_search"}) {
    auto out=production;out.base_linear=f.photo.sdr;
    for(std::size_t p=0;p<n;++p) {
      const auto* s=&f.photo.sdr.pixels[p*3];const auto* h=&f.photo.hdr.pixels[p*3];
      const float g=gain_for(p3_luminance(s[0],s[1],s[2]),p3_luminance(h[0],h[1],h[2]),f.offset);
      const float safe=std::max(g,gain_for(1.0F,std::max({h[0],h[1],h[2]}),f.offset));
      const float pos=range>1e-6F ? std::clamp(((policy=="preserve_all"?g:safe)-low)/range,0.0F,1.0F)*255 : 0;
      float q=(policy=="preserve_all"?std::round(pos):std::ceil(pos-1e-3F))/255;
      if(policy=="selective_code_search") {
        // A deliberately ordinary exhaustive baseline. On the same repair
        // pixels, choose the 8-bit code minimizing SDR squared error, subject
        // to the existing pixel HDR tolerance and [0,1] base constraint.
        // Retained pixels use exactly the production codes.
        if(!mask[p]) {out.gain_map.pixels[p]=production.gain_map.pixels[p];continue;}
        double best=1e100;bool found=false;
        const float tolerance=1e-3F*std::max({h[0],h[1],h[2]})+1e-5F;
        for(unsigned code=0;code<256;++code) {
          const float m=std::exp2(low+range*float(code)/255);double error=0;float hdr_error=0;
          for(unsigned c=0;c<3;++c) {
            const float base=std::clamp((h[c]+f.offset)/m-f.offset,0.0F,1.0F);
            const float d=base-s[c];error+=d*d;
            hdr_error=std::max(hdr_error,std::abs(std::max(0.0F,(base+f.offset)*m-f.offset)-h[c]));
          }
          if(hdr_error<=tolerance && error<best) {best=error;q=float(code)/255;found=true;}
        }
        if(!found) q=production.gain_map.pixels[p];
      }
      out.gain_map.pixels[p]=q;
      if(policy=="preserve_all")continue;
      const float inv=std::exp2(-(low+range*q));
      for(unsigned c=0;c<3;++c)
        out.base_linear.pixels[p*3+c]=std::clamp((h[c]+f.offset)*inv-f.offset,0.0F,1.0F);
    }
    emit(f,policy,out,mask);
  }
}
Fixture read_pair(const char* path) {
  std::ifstream file(path,std::ios::binary);
  std::uint32_t width{},height{};float offset{};
  file.read(reinterpret_cast<char*>(&width),sizeof(width));
  file.read(reinterpret_cast<char*>(&height),sizeof(height));
  file.read(reinterpret_cast<char*>(&offset),sizeof(offset));
  Fixture f{"real_IMG_0017_1024_edge",{},offset};
  f.photo.sdr=FloatImage(width,height,3);f.photo.hdr=FloatImage(width,height,3);
  const auto bytes=static_cast<std::streamsize>(f.photo.sdr.pixels.size()*sizeof(float));
  file.read(reinterpret_cast<char*>(f.photo.sdr.pixels.data()),bytes);
  file.read(reinterpret_cast<char*>(f.photo.hdr.pixels.data()),bytes);
  if(!file)throw std::runtime_error("incomplete research pair file");
  f.photo.dual_rendition=true;
  f.photo.authored_gain_map.base_offset.fill(offset);
  f.photo.authored_gain_map.alternate_offset.fill(offset);
  return f;
}
void approximate_feasibility() {
  Fixture f{"approximate_gain_feasible",{},0};
  f.photo.sdr=FloatImage(1,1,3);f.photo.hdr=FloatImage(1,1,3);
  f.photo.sdr.pixels={.001F,.001F,1};f.photo.hdr.pixels={.0025F,.0025F,2};
  f.photo.dual_rendition=true;
  run(f);
  auto out=gain_map_from_renditions(f.photo,GainMapWriterProfile::apple_strict);
  out.base_linear=f.photo.sdr;
  const float low=rational_value(out.metadata.gain_min),high=rational_value(out.metadata.gain_max);
  float best=1e10F;
  for(unsigned code=0;code<256;++code) {
    const float m=std::exp2(low+(high-low)*float(code)/255);float error=0;
    for(unsigned c=0;c<3;++c)error=std::max(error,std::abs(f.photo.sdr.pixels[c]*m-f.photo.hdr.pixels[c]));
    if(error<best) {best=error;out.gain_map.pixels[0]=float(code)/255;}
  }
  emit(f,"code_only_preserve_search",out,repair_mask(f));
}
int main(int argc,char** argv) {
  std::cout<<std::setprecision(10);
  std::cout<<"fixture,policy,pixels,repair_pct,sdr_any_change_pct,sdr_change_over_1_255_pct,sdr_max_abs,sdr_mse,hdr_max_abs,hdr_mse,hdr_relative_p99_pct,hdr_relative_max_pct,hdr_over_classification_tolerance_pct,gain_min,gain_max\n";
  // A 256-point 0..4 ramp would accidentally land exactly on all codes. Use
  // an interval with a forced zero minimum to expose ordinary quantization.
  run(shared("shared_0p1_to_4_stops",.1F,4,0,false));
  run(shared("sparse_colour_edits",.1F,4,0,true));
  run(shared("signed_gain_with_offsets",-2,4,1.0F/64,true));
  run(shared("wide_19_stop_stress",.1F,19,0,false));
  run(resize_edges());
  approximate_feasibility();
  if(argc>1)run(read_pair(argv[1]));
}

#pragma once
// Encoder fixtures contain finished planes, independent of the retired renderer.
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/rational.hpp"
#include <algorithm>
#include <cmath>
namespace hyperdr::test {
inline GainMapResult encoded_pair(const PhotoRenditions& photo, bool mono = true) {
  GainMapResult out;
  out.base_linear = photo.sdr;
  out.clamp_srgb = photo.clamp_srgb;
  out.headroom_stops = photo.stats.headroom_stops;
  out.stats = photo.stats;
  auto& metadata=out.metadata;
  metadata.alternate_headroom=rational_from_float(out.headroom_stops);
  if(out.headroom_stops==0)metadata.alternate_headroom={1,1U<<23};
  const unsigned channels=mono?1:3;
  out.gain_map=FloatImage(photo.sdr.width,photo.sdr.height,channels);
  if(!mono){metadata.flags|=0x80;metadata.channels.resize(3);}
  float low=0,high=0;
  for(unsigned y=0;y<photo.sdr.height;++y)for(unsigned x=0;x<photo.sdr.width;++x){
    const auto* hdr=photo.hdr_pixel(x,y);
    if(mono){
      const float gain=photo.hdr_is_source ? std::log2(std::max({1.F,hdr[0],hdr[1],hdr[2]})) : std::max({0.F,std::log2(std::max(hdr[0],1e-12F)/std::max(photo.sdr.at(x,y,0),1e-12F)),std::log2(std::max(hdr[1],1e-12F)/std::max(photo.sdr.at(x,y,1),1e-12F)),std::log2(std::max(hdr[2],1e-12F)/std::max(photo.sdr.at(x,y,2),1e-12F))});
      out.gain_map.at(x,y,0)=gain; high=std::max(high,gain);
      for(unsigned c=0;c<3;++c)out.base_linear.at(x,y,c)=hdr[c]/std::exp2(gain);
    }else for(unsigned c=0;c<3;++c){
      const float gain=std::log2(std::max(hdr[c],1e-12F)/std::max(photo.sdr.at(x,y,c),1e-12F));
      out.gain_map.at(x,y,c)=gain; low=std::min(low,gain);high=std::max(high,gain);
    }
  }
  if(mono)high=std::max(high,out.headroom_stops);
  metadata.gain_min=rational_from_float(low); metadata.gain_max=rational_from_float(high);
  metadata.gamma={1,1};metadata.base_offset={0,1};metadata.alternate_offset={0,1};
  if(!mono)for(auto& c:metadata.channels){c.gain_min=metadata.gain_min;c.gain_max=metadata.gain_max;c.gamma={1,1};c.base_offset={0,1};c.alternate_offset={0,1};}
  for(auto& value:out.gain_map.pixels)value=high>low?(value-low)/(high-low):0;
  return out;
}
inline GainMapResult gradient_pair(const FloatImage& base,float stops=3) {
  GainMapResult out;out.base_linear=base;out.gain_map=FloatImage(base.width,base.height,1);
  out.headroom_stops=stops;out.metadata.gain_max=rational_from_float(stops);out.metadata.alternate_headroom=rational_from_float(stops);
  out.metadata.base_offset={0,1};out.metadata.alternate_offset={0,1};out.metadata.gamma={1,1};
  out.stats.headroom_stops=stops;out.stats.headroom_linear=std::exp2(stops);
  for(unsigned y=0;y<base.height;++y)for(unsigned x=0;x<base.width;++x){
    out.gain_map.at(x,y,0)=stops>0?float(x)/std::max(1U,base.width-1):0;
    const float divisor=std::max({1.F,base.at(x,y,0),base.at(x,y,1),base.at(x,y,2)});
    for(unsigned c=0;c<3;++c)out.base_linear.at(x,y,c)/=divisor;
  }
  return out;
}
inline PhotoRenditions decoded_pair(const GainMapResult& gain) {
  PhotoRenditions out;out.sdr=gain.base_linear;out.stats=gain.stats;
  out.hdr=reconstruct_gain_map(gain.base_linear,gain.gain_map,gain.metadata,gain.headroom_stops);
  return out;
}
}

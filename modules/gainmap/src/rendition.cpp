#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"
#include <algorithm>
#include <cmath>
#include <stdexcept>
namespace hyperdr {
PhotoRenditions renditions_from_gain_map(GainMapResult images, bool include_hdr) {
  PhotoRenditions out;
  if(include_hdr) out.hdr=reconstruct_gain_map(images.base_linear, images.gain_map,
      images.metadata, images.headroom_stops, nullptr, images.clamp_srgb);
  out.sdr=std::move(images.base_linear); out.stats=images.stats;
  out.clamp_srgb=images.clamp_srgb;
  if(!include_hdr) {out.stats.headroom_stops=0;out.stats.headroom_linear=1;}
  return out;
}
GainMapResult gain_map_from_renditions(PhotoRenditions images) {
  const auto& sdr=images.sdr; const auto& hdr=images.hdr;
  if(sdr.channels!=3 || hdr.channels!=3 || sdr.width!=hdr.width || sdr.height!=hdr.height)
    throw std::invalid_argument("gain-map packaging requires matching SDR and HDR renditions");
  const auto dimensions=choose_gain_dimensions(sdr);
  FloatImage stops(dimensions.width,dimensions.height,1);
  parallel_for_rows(stops.height,[&](std::uint32_t gy) {
    const auto y0=grid_cell_edge(gy,sdr.height,stops.height), y1=grid_cell_edge(gy+1,sdr.height,stops.height);
    for(std::uint32_t gx=0;gx<stops.width;++gx) {
      const auto x0=grid_cell_edge(gx,sdr.width,stops.width), x1=grid_cell_edge(gx+1,sdr.width,stops.width);
      double sum=0;
      for(auto y=y0;y<y1;++y) for(auto x=x0;x<x1;++x) {
        const auto i=(static_cast<std::size_t>(y)*sdr.width+x)*3;
        const float base=p3_luminance(sdr.pixels[i],sdr.pixels[i+1],sdr.pixels[i+2]);
        const float alternate=p3_luminance(hdr.pixels[i],hdr.pixels[i+1],hdr.pixels[i+2]);
        if(base>1e-6F) sum+=std::clamp(std::log2(std::max(alternate,base)/base),0.0F,images.stats.headroom_stops);
      }
      stops.at(gx,gy,0)=static_cast<float>(sum/((x1-x0)*(y1-y0)));
    }
  });
  const float maximum=*std::max_element(stops.pixels.begin(),stops.pixels.end());
  if(maximum>0) for(auto& c:stops.pixels) c/=maximum;
  const float gamma=maximum>0 ? choose_gain_gamma(stops.pixels) : 1;
  for(std::uint32_t y=0;y<stops.height;++y) for(std::uint32_t x=0;x<stops.width;++x)
    stops.at(x,y,0)=quantize_gain_code_dithered(encode_gain_code(stops.at(x,y,0),gamma),x,y);
  GainMapResult out;
  out.base_linear=std::move(images.sdr); out.gain_map=std::move(stops);
  out.metadata.gain_min={0,1}; out.metadata.gain_max=rational_from_float(maximum);
  out.metadata.gamma=rational_from_float(gamma);
  out.metadata.base_offset={0,1}; out.metadata.alternate_offset={0,1};
  out.metadata.base_headroom={0,1}; out.metadata.alternate_headroom=out.metadata.gain_max;
  out.clamp_srgb=images.clamp_srgb; out.exposure_ev=images.stats.exposure_ev;
  out.headroom_stops=maximum; out.stats=images.stats;
  out.stats.gain_max_stops=maximum; out.stats.gain_gamma=gamma;
  measure_quantized_gain(out.stats,out.gain_map,maximum,gamma,images.stats.headroom_stops);
  return out;
}
}  // namespace hyperdr

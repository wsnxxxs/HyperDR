#pragma once
// Test-only counterfactuals: retain the compressed base and tone-map metadata,
// replace the entire gain image with its integer zero code. No SPS rewriting.
// The HEIC helper deliberately accepts the single-tile files used by these
// small synthetic gates; it rejects other layouts rather than guessing.
#include "hevc/hevc.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/items.hpp"
#include "gain_plane.hpp"
#include <map>

namespace hyperdr::test {
inline unsigned zero_code(const GainMapChannelMetadata& m) {
  const auto value=[](Rational r){return double(r.numerator)/r.denominator;};
  const double low=value(m.gain_min),high=value(m.gain_max),gamma=value(m.gamma);
  const double position=high>low ? std::pow(std::clamp(-low/(high-low),0.0,1.0),gamma) : 0;
  const auto code=unsigned(std::lround(position*255));
  if(std::abs(low+(high-low)*std::pow(double(code)/255,1/gamma))>1e-6)
    throw std::runtime_error("control metadata has no integer zero code");
  return code;
}
inline std::vector<std::uint8_t> bare_jpeg(std::vector<std::uint8_t> bytes,
    const std::vector<JpegAppSegment>& apps, std::size_t offset, bool all) {
  for(auto it=apps.rbegin();it!=apps.rend();++it){
    const std::string prefix(it->payload.begin(),it->payload.end());
    if(all || prefix.starts_with("MPF") || prefix.starts_with("urn:iso:")){
      const auto at=it->offset-offset;
      bytes.erase(bytes.begin()+at,bytes.begin()+at+it->payload.size()+4);
    }
  }
  return bytes;
}
inline void zero_jpeg_control(const std::filesystem::path& input,const std::filesystem::path& output) {
  const auto bytes=read_binary_file(input);const auto parsed=parse_gain_map_jpeg(bytes);
  // Dimensions are supplied by the caller's gain plane via ImageIO; obtain
  // them from JPEG SOF as well so this helper is independent of platform APIs.
  unsigned width=0,height=0;
  for(std::size_t p=parsed.gain_offset+2;p+9<bytes.size();){
    if(bytes[p]!=255)throw std::runtime_error("control JPEG marker");
    const auto marker=bytes[p+1];const auto size=(unsigned(bytes[p+2])<<8)|bytes[p+3];
    if(marker==0xc0 || marker==0xc1 || marker==0xc2){
      height=(unsigned(bytes[p+5])<<8)|bytes[p+6];width=(unsigned(bytes[p+7])<<8)|bytes[p+8];break;
    }
    if(size<2 || marker==0xda)break;p+=2+size;
  }
  if(!width || !height)throw std::runtime_error("control JPEG dimensions");
  GainMapResult zero;zero.base_linear=FloatImage(width,height,3);
  const auto channels=gain_map_channel_count(parsed.metadata);
  zero.gain_map=FloatImage(width,height,channels);zero.metadata=parsed.metadata;
  for(unsigned c=0;c<channels;++c){const float value=zero_code(gain_map_channel(parsed.metadata,c))/255.F;
    for(std::size_t p=c;p<zero.gain_map.pixels.size();p+=channels)zero.gain_map.pixels[p]=value;}
  const auto encoded=encode_gain_map_jpeg(zero,{},100),primary=bare_jpeg(
      {bytes.begin(),bytes.begin()+parsed.primary_size},parsed.app_segments[0],0,false);
  const auto z=parse_gain_map_jpeg(encoded);
  const auto gain=bare_jpeg({encoded.begin()+z.gain_offset,encoded.begin()+z.gain_offset+z.gain_size},z.app_segments[1],z.gain_offset,true);
  const auto control=assemble_gain_map_jpeg(primary,gain,parsed.metadata);
  const auto check=parse_gain_map_jpeg(control);
  const auto retained=bare_jpeg({control.begin(),control.begin()+check.primary_size},check.app_segments[0],0,false);
  if(primary!=retained || serialize_tmap_payload(parsed.metadata)!=serialize_tmap_payload(check.metadata))
    throw std::runtime_error("control changed JPEG base or tmap metadata");
  write_binary_file_atomic(output,control,true);
  const auto plane=read_gain_plane(output);
  for(std::size_t i=0;i<plane.codes.pixels.size();++i)
    if(std::lround(plane.codes.pixels[i]*255)!=long(zero_code(gain_map_channel(parsed.metadata,i%channels))))
      throw std::runtime_error("control JPEG gain is not uniformly zero");
}
inline void zero_heic_control(const std::filesystem::path& input,const std::filesystem::path& output) {
  using namespace container;
  namespace h=codec::hevc;
  const auto bytes=read_binary_file(input);Box meta;
  for(auto b:children(bytes,0,bytes.size()))if(b.type=="meta")meta=b;
  if(!meta.size)throw std::runtime_error("control HEIC meta missing");
  std::map<unsigned,Bytes> items;std::vector<ItemDesc> descriptions;std::vector<Box> props;
  for(auto b:children(bytes,meta.offset+12,meta.offset+meta.size)){
    if(b.type=="iinf")descriptions=parse_iinf(std::span(bytes).subspan(b.offset,b.size));
    if(b.type=="iloc"){
      const auto v=std::span(bytes).subspan(b.offset,b.size);
      if(v.size()<16 || v[8]!=1 || v[12]!=0x44 || v[13]!=0)throw std::runtime_error("control expects writer iloc v1");
      const auto count=be16(v,14);if(v.size()!=16+16*std::size_t(count))throw std::runtime_error("control iloc size");
      for(unsigned i=0;i<count;++i){const auto p=16+i*16;
        if(be16(v,p+2)!=0 || be16(v,p+4)!=0 || be16(v,p+6)!=1)throw std::runtime_error("control iloc extent");
        const auto offset=be32(v,p+8),size=be32(v,p+12);
        if(offset>bytes.size() || size>bytes.size()-offset)throw std::runtime_error("control item range");
        items.emplace(be16(v,p),Bytes(bytes.begin()+offset,bytes.begin()+offset+size));
      }
    }
    if(b.type=="iprp")for(auto p:children(bytes,b.offset+8,b.offset+b.size))
      if(p.type=="ipco")props=children(bytes,p.offset+8,p.offset+p.size);
  }
  const auto refs=find_tmap_references(bytes);const auto& grid=items.at(refs.base_id);
  const auto desc=std::find_if(descriptions.begin(),descriptions.end(),[&](const auto& d){return d.id==refs.base_id;});
  if(desc==descriptions.end() || desc->type!="grid" || grid.size()!=8 || grid[2]!=0 || grid[3]!=0)
    throw std::runtime_error("control requires one cropped writer tile");
  const unsigned width=be16(grid,4),height=be16(grid,6);
  h::EncodedSequence base;HeifNclx color;Bytes icc;bool have_nclx=false;
  for(const auto& p:props){
    if(p.type=="hvcC" && base.sps.empty()){
      const auto v=std::span(bytes).subspan(p.offset+8,p.size-8);if(v.size()<23)throw std::runtime_error("control hvcC");
      std::size_t at=23;
      for(unsigned i=0;i<v[22];++i){const auto type=v[at]&63;const auto count=be16(v,at+1);at+=3;
        if(count!=1)throw std::runtime_error("control parameter count");const auto n=be16(v,at);at+=2;
        if(n>v.size()-at)throw std::runtime_error("control parameter length");
        auto* target=type==32?&base.vps:type==33?&base.sps:type==34?&base.pps:nullptr;
        if(target)target->assign(v.begin()+at,v.begin()+at+n);at+=n;
      }
    }
    if(p.type=="colr" && p.size>=12){const std::string kind(reinterpret_cast<const char*>(bytes.data()+p.offset+8),4);
      if(kind=="nclx" && !have_nclx){
        if(p.size!=19)throw std::runtime_error("control nclx size");
        color={be16(bytes,p.offset+12),be16(bytes,p.offset+14),be16(bytes,p.offset+16),bool(bytes[p.offset+18]&128)};have_nclx=true;
      }
      if(kind=="prof" && icc.empty())icc.assign(bytes.begin()+p.offset+12,bytes.begin()+p.offset+p.size);
    }
  }
  if(base.vps.empty()||base.sps.empty()||base.pps.empty()||icc.empty()||!have_nclx)throw std::runtime_error("control base properties missing");
  // Our writer lays out base grid then its one tile. Confirm the type instead
  // of reading an arbitrary decodable item (which might be the gain tile).
  const auto tile=std::find_if(descriptions.begin(),descriptions.end(),[&](const auto& d){return d.id==refs.base_id+1;});
  if(tile==descriptions.end()||tile->type!="hvc1")throw std::runtime_error("control base tile missing");
  base.samples.push_back(items.at(tile->id));
  const auto metadata=parse_tmap_payload(extract_tmap_payload(bytes));const auto code=zero_code(gain_map_channel(metadata,0));
  const auto gain=h::encode(1,[&](std::size_t,h::YuvTile& t){h::luma_tile(h::tile_grid(width,height),0,
    [&](unsigned,unsigned,unsigned n,float* values){std::fill_n(values,n,code/255.F);},t);},{95,false,false,{2,2,1}});
  HeifEncodedImage b{base,width,height,color,std::nullopt,icc},g{gain,width,height,{2,2,1,true},std::nullopt,{}};
  HeifWriteOptions options;options.gain_metadata=metadata;
  for(const auto& d:descriptions){
    if(d.type=="Exif"){const auto& e=items.at(d.id);if(e.size()<4||be32(e,0)!=0)throw std::runtime_error("control Exif");options.exif={e.begin()+4,e.end()};}
    if(d.type=="mime"){const auto& x=items.at(d.id);options.xmp.assign(x.begin(),x.end());}
  }
  const auto control=write_heif(b,&g,options);
  if(extract_tmap_payload(control)!=extract_tmap_payload(bytes))throw std::runtime_error("control changed HEIC metadata");
  write_binary_file_atomic(output,control,true);
  const auto plane=read_heic_gain_plane(output);
  if(std::any_of(plane.codes.pixels.begin(),plane.codes.pixels.end(),[&](float v){return std::lround(v*255)!=long(code);}))
    throw std::runtime_error("control gain is not uniformly zero");
}
inline void make_zero_gain_control(const std::filesystem::path& input,const std::filesystem::path& output) {
  if(input.extension()==".heic")zero_heic_control(input,output);else zero_jpeg_control(input,output);
}
} // namespace hyperdr::test

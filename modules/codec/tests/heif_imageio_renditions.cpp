// Independent ImageIO HDR gate: write the exact immutable PhotoRenditions::hdr
// passed to encode_hdr_heic, before any transfer function or YUV conversion.
#include "hyperdr/codec/encoders.hpp"
#include "../../../tests/hevc/gain_plane.hpp"
#include "../../../tests/hevc/zero_gain_control.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/image/frame.hpp"
#include <pthread.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <exception>
#include <fstream>
#include <iomanip>
#include <iostream>
using namespace hyperdr;
namespace {
void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
void dump(const std::filesystem::path& path,const FloatImage& image){
  std::ofstream out(path,std::ios::binary);const std::array<std::uint32_t,3> shape{image.width,image.height,image.channels};
  out.write(reinterpret_cast<const char*>(shape.data()),sizeof(shape));out.write(reinterpret_cast<const char*>(image.pixels.data()),image.pixels.size()*sizeof(float));
  require(bool(out),"write exact HDR reference");
}
FloatImage read(const std::filesystem::path& path){
  std::ifstream in(path,std::ios::binary);std::array<std::uint32_t,3> shape{};in.read(reinterpret_cast<char*>(shape.data()),sizeof(shape));
  require(bool(in)&&shape[0]&&shape[1]&&shape[0]<=4096&&shape[1]<=4096&&shape[2]==3,"HDR reference shape");
  FloatImage image(shape[0],shape[1],3);in.read(reinterpret_cast<char*>(image.pixels.data()),image.pixels.size()*sizeof(float));
  require(bool(in)&&in.peek()==std::char_traits<char>::eof(),"HDR reference payload");return image;
}
// U13: measure the 8-bit floor in this run, using exactly the product's
// conversion and dither. No HEVC encode/decode participates in this reference.
FloatImage ideal_eight_bit_hdr(const GainMapResult& packed) {
  namespace h = codec::hevc;
  const auto& base = packed.base_linear;
  require(base.width <= h::kTileSize && base.height <= h::kTileSize,
          "ideal-floor fixture must fit one tile");
  auto tile = h::make_tile(8);
  h::rgb_tile(h::tile_grid(base.width, base.height), 0,
      [&](unsigned y, unsigned x, unsigned count, float* rgb) {
        for (unsigned i = 0; i < count; ++i)
          for (unsigned c = 0; c < 3; ++c)
            rgb[3*i+c] = srgb_oetf(base.at(x+i, y, c));
      }, 1, true, tile);
  const auto chroma = [&](bool red, float x, float y) {
    constexpr unsigned end = h::kTileSize/2-1;
    x = std::clamp(x, 0.F, float(end));
    y = std::clamp(y, 0.F, float(end));
    const auto x0 = unsigned(x), y0 = unsigned(y);
    const auto x1 = std::min(end, x0+1), y1 = std::min(end, y0+1);
    const float tx = x-x0, ty = y-y0;
    const auto sample = [&](unsigned a, unsigned b) {
      return float(red ? tile.cr_at(a,b) : tile.cb_at(a,b));
    };
    return (((sample(x0,y0)*(1-tx)+sample(x1,y0)*tx)*(1-ty) +
             (sample(x0,y1)*(1-tx)+sample(x1,y1)*tx)*ty)-128.F)/255.F;
  };
  FloatImage quantized(base.width, base.height, 3);
  for (unsigned y = 0; y < base.height; ++y)
    for (unsigned x = 0; x < base.width; ++x) {
      const float luma = tile.luma_at(x,y)/255.F;
      const float cb = chroma(false, (float(x)-.5F)/2, (float(y)-.5F)/2);
      const float cr = chroma(true, (float(x)-.5F)/2, (float(y)-.5F)/2);
      const float r = luma+1.5748F*cr, b = luma+1.8556F*cb;
      const float g = (luma-.2126F*r-.0722F*b)/.7152F;
      const std::array<float,3> rgb{r,g,b};
      for (unsigned c = 0; c < 3; ++c)
        quantized.at(x,y,c) = srgb_eotf(std::clamp(rgb[c],0.F,1.F));
    }
  return reconstruct_gain_map(quantized, packed.gain_map, packed.metadata,
                              packed.headroom_stops);
}
void generate(const std::filesystem::path& directory){
  std::filesystem::create_directories(directory);PhotoRenditions photo;photo.hdr=FloatImage(256,128,3);
  for(unsigned y=0;y<photo.hdr.height;++y)for(unsigned x=0;x<photo.hdr.width;++x){
    const float t=float(x)/(photo.hdr.width-1),v=.025F+3.8F*t*t;
    photo.hdr.at(x,y,0)=v;photo.hdr.at(x,y,1)=v*(.6F+.2F*y/photo.hdr.height);photo.hdr.at(x,y,2)=v*.42F;
  }
  // No independently reconstructed or separately rendered reference: these are
  // the very same float values the encoder reads below, byte for byte.
  dump(directory/"reference-hdr.f32",photo.hdr);
  for(auto encoding:{HdrEncoding::Pq,HdrEncoding::Hlg}){
    const auto name=encoding==HdrEncoding::Pq?"pq":"hlg";
    write_binary_file_atomic(directory/(std::string(name)+".heic"),encode_hdr_heic(photo,{},95,encoding),true);
    std::cout<<name<<" exact pre-encode linear P3 reference 256x128 on 512KB stack\n";
  }
  photo.sdr=photo.hdr;for(auto& v:photo.sdr.pixels)v*=.25F;
  photo.hdr_is_source=true;photo.stats.headroom_stops=2;photo.stats.headroom_linear=4;
  const auto packed=gain_map_from_renditions(photo,GainMapWriterProfile::apple_strict);
  dump(directory/"adaptive8-ideal-hdr.f32",ideal_eight_bit_hdr(packed));
  for(auto depth:{8,10})write_binary_file_atomic(directory/("adaptive"+std::to_string(depth)+".heic"),
      encode_adaptive_heic(packed,{},95,depth),true);
  // Offsets are authored values, not an encoder-selected fixed constant.
  GainMapResult pair;pair.base_linear=FloatImage(64,32,3);std::fill(pair.base_linear.pixels.begin(),pair.base_linear.pixels.end(),.2F);
  pair.gain_map=FloatImage(64,32,1);std::fill(pair.gain_map.pixels.begin(),pair.gain_map.pixels.end(),.5F);
  pair.metadata.gain_max={17,10};pair.metadata.alternate_headroom={17,10};pair.metadata.gamma={13,10};
  pair.metadata.base_offset={21,1000};pair.metadata.alternate_offset={13,1000};pair.headroom_stops=1.7F;
  const auto expected=serialize_tmap_payload(pair.metadata);
  for(auto depth:{8,10}){
    const auto bytes=encode_adaptive_heic(pair,{},95,depth);
    require(extract_tmap_payload(bytes)==expected,"authored gain metadata changed during HEVC encoding");
    const auto parsed=parse_tmap_payload(extract_tmap_payload(bytes));
    require(gain_map_channel_count(parsed)==1,"authored mono channels lost");
  }
  auto rgb=pair;rgb.metadata.flags|=0x80;rgb.metadata.channels.assign(3,gain_map_channel(pair.metadata,0));
  rgb.gain_map=FloatImage(64,32,3);
  for(unsigned c=0;c<3;++c){rgb.metadata.channels[c].base_offset={int(21+c),1000};rgb.metadata.channels[c].alternate_offset={int(13+c),1000};}
  for(auto depth:{8,10}){bool rejected=false;try{(void)encode_adaptive_heic(rgb,{},95,depth);}catch(const std::invalid_argument& e){rejected=std::string(e.what()).find("multichannel")!=std::string::npos;}
    require(rejected,"apple_strict must reject authored RGB rather than drop channels or offsets");}
  std::cout<<"authored mono metadata exact; authored RGB rejected by unchanged apple_strict\n";
}

FloatImage linear_signal(FloatImage image, const std::string& mode) {
  if (mode=="pq" || mode=="hlg") for (std::size_t i=0;i<image.pixels.size();i+=3) {
    auto* p=&image.pixels[i];
    auto rgb=mode=="hlg" ? hlg_decode({p[0],p[1],p[2]}) : std::array<float,3>{pq_eotf(p[0]),pq_eotf(p[1]),pq_eotf(p[2])};
    rgb=rec2020_to_linear_p3(rgb[0],rgb[1],rgb[2]); std::copy(rgb.begin(),rgb.end(),p);
  }
  return image;
}
void compare_frame(const std::filesystem::path& input, const std::filesystem::path& spec_path,
                   unsigned width, unsigned height, const std::string& mode) {
  const auto candidate=linear_signal(read(input),mode);
  const auto spec_bytes=read_binary_file(spec_path);
  const auto spec=parse_frame_spec(json::parse(std::string(spec_bytes.begin(),spec_bytes.end())));
  const auto layout=layout_frame(spec,width,height);
  const auto expected=frame_image(FloatImage(width,height,3),spec,layout);
  require(candidate.width==expected.width && candidate.height==expected.height,"frame reference shape");
  std::vector<float> delta; double white_min=100,white_max=0,white_sum=0;unsigned whites=0;
  for(unsigned y=0;y<layout.height;++y)for(unsigned x=0;x<layout.width;++x){
    const int d=std::max({int(layout.photo.x)-int(x),int(x)-int(layout.photo.x+width-1),
                         int(layout.photo.y)-int(y),int(y)-int(layout.photo.y+height-1)});
    if(d<=3)continue;
    std::array<float,3>a{},b{};for(unsigned c=0;c<3;++c){a[c]=expected.at(x,y,c);b[c]=candidate.at(x,y,c);}
    delta.push_back(delta_e_itp(a,b));
    if(*std::min_element(a.begin(),a.end())>=.99999F){
      const double lum=p3_luminance(b[0],b[1],b[2]);white_min=std::min(white_min,lum);white_max=std::max(white_max,lum);white_sum+=lum;++whites;
    }
  }
  require(!delta.empty(),"empty frame colour reference");std::sort(delta.begin(),delta.end());
  std::cout<<std::setprecision(12)<<"{\"delta_e_itp_p99\":"<<delta[std::size_t(std::ceil(delta.size()*.99))-1]
           <<",\"white_pixels\":"<<whites<<",\"white_min\":"<<white_min<<",\"white_max\":"<<white_max<<",\"white_mean\":"<<(whites?white_sum/whites:0)<<"}\n";
}
void compare_photo(const std::filesystem::path& framed_path, const std::filesystem::path& plain_path,
                   unsigned left,unsigned top,unsigned k,const std::string& mode) {
  const auto framed=linear_signal(read(framed_path),mode), plain=linear_signal(read(plain_path),mode);
  double sum=0;std::uint64_t count=0;float peak=0,reference_peak=0;
  require(plain.width>2*k && plain.height>2*k,"empty photograph interior");
  for(unsigned y=k;y<plain.height-k;++y)for(unsigned x=k;x<plain.width-k;++x)for(unsigned c=0;c<3;++c){
    const auto a=plain.at(x,y,c),b=framed.at(x+left,y+top,c);
    if(a>=.02F&&b>=.02F){sum+=std::abs(std::log2(double(b)/a));++count;}
  }
  for(unsigned y=k;y<plain.height-k;++y)for(unsigned x=k;x<plain.width-k;++x){
    peak=std::max(peak,p3_luminance(framed.at(x+left,y+top,0),framed.at(x+left,y+top,1),framed.at(x+left,y+top,2)));
    reference_peak=std::max(reference_peak,p3_luminance(plain.at(x,y,0),plain.at(x,y,1),plain.at(x,y,2)));
  }
  require(count>0 && reference_peak>0,"empty photo comparison");
  std::cout<<std::setprecision(12)<<"{\"mean_abs_log2\":"<<sum/count<<",\"reference_peak\":"<<reference_peak<<",\"candidate_peak\":"<<peak<<",\"peak_relative_error\":"<<std::abs(peak-reference_peak)/reference_peak<<"}\n";
}
void signed_fixture(const std::filesystem::path& path) {
  PhotoRenditions photo;photo.sdr=FloatImage(128,96,3);photo.hdr=photo.sdr;
  for(unsigned y=0;y<96;++y)for(unsigned x=0;x<128;++x)for(unsigned c=0;c<3;++c){
    const float base=.12F+.35F*x/127;
    photo.sdr.at(x,y,c)=base;
    photo.hdr.at(x,y,c)=base*(x<32?.71F:4.F);
  }
  photo.dual_rendition=true;photo.authored_gain_channels=1;
  photo.authored_gain_map.base_offset.fill(1.F/64);photo.authored_gain_map.alternate_offset.fill(1.F/64);
  photo.stats.headroom_stops=2;photo.stats.headroom_linear=4;
  const auto pair=gain_map_from_renditions(photo,GainMapWriterProfile::apple_strict);
  require(rational_value(pair.metadata.gain_min)<0,"signed fixture lost negative gain");
  write_binary_file_atomic(path,encode_adaptive_heic(pair,{},95,10),true);
}


}
int execute(int argc,char** argv){try{
  if(argc==4 && std::string(argv[1])=="--zero-gain-control") {
    test::make_zero_gain_control(argv[2],argv[3]); return 0;
  }
  if(argc==3 && std::string(argv[1])=="--signed-fixture") { signed_fixture(argv[2]); return 0; }
  if(argc==7 && std::string(argv[1])=="--compare-frame") {
    compare_frame(argv[2],argv[3],std::stoul(argv[4]),std::stoul(argv[5]),argv[6]); return 0;
  }
  if(argc==8 && std::string(argv[1])=="--compare-photo") {
    compare_photo(argv[2],argv[3],std::stoul(argv[4]),std::stoul(argv[5]),std::stoul(argv[6]),argv[7]); return 0;
  }
  if (argc==4 && std::string(argv[1])=="--gain-plane") {
    const auto plane=test::read_gain_plane(argv[2]); dump(argv[3],plane.codes);
    std::cout<<"{\"bits\":"<<plane.bits<<",\"chroma_support\":"<<plane.chroma_support<<",\"metadata\":[";
    for(unsigned c=0;c<gain_map_channel_count(plane.metadata);++c){
      const auto m=gain_map_channel(plane.metadata,c);if(c)std::cout<<',';
      std::cout<<std::setprecision(12)<<'['<<rational_value(m.gain_min)<<','<<rational_value(m.gain_max)<<','<<rational_value(m.gamma)<<']';
    }
    std::cout<<"]}\n";
    return 0;
  }
  if(argc==4&&(std::string(argv[1])=="--compare"||std::string(argv[1])=="--compare-pq"||std::string(argv[1])=="--compare-hlg")){
    auto candidate=read(argv[3]);const std::string mode=argv[1];
    if(mode!="--compare")for(std::size_t i=0;i<candidate.pixels.size();i+=3){
      auto* v=candidate.pixels.data()+i;
      auto rgb=mode=="--compare-hlg"?hlg_decode({v[0],v[1],v[2]}):std::array<float,3>{pq_eotf(v[0]),pq_eotf(v[1]),pq_eotf(v[2])};
      rgb=rec2020_to_linear_p3(rgb[0],rgb[1],rgb[2]);std::copy(rgb.begin(),rgb.end(),v);
    }
    const auto metrics=measure_hdr_fidelity(read(argv[2]),candidate);
    std::cout<<std::setprecision(12)<<"{\"psnr_pq_db\":"<<metrics.psnr_pq_db<<",\"delta_e_itp_p99\":"<<metrics.delta_e_itp_p99
      <<",\"delta_e_itp_mean\":"<<metrics.delta_e_itp_mean<<",\"reference_mean\":"<<metrics.reference_mean<<",\"candidate_mean\":"<<metrics.candidate_mean<<"}\n";return 0;
  }
  require(argc==2,"usage: heif_imageio_renditions OUTPUT_DIRECTORY | --compare REF CAND");
  // All command modes already run on main's 512 KiB worker.
  generate(argv[1]);
  return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}

int main(int argc,char** argv) {
  struct Command { int argc; char** argv; int result{1}; } command{argc,argv};
  pthread_attr_t attr;
  if(pthread_attr_init(&attr)!=0)return 1;
  if(pthread_attr_setstacksize(&attr,512*1024)!=0){pthread_attr_destroy(&attr);return 1;}
  pthread_t thread;
  const auto status=pthread_create(&thread,&attr,[](void* value)->void* {
    auto& c=*static_cast<Command*>(value);c.result=execute(c.argc,c.argv);return nullptr;
  },&command);
  pthread_attr_destroy(&attr);
  if(status!=0 || pthread_join(thread,nullptr)!=0)return 1;
  return command.result;
}

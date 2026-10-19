#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "internal/decode_bytes.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/image/orientation.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include <thread>
#include <jpeglib.h>
#include <chrono>
#include <unistd.h>
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ultrahdr_api.h>
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
using namespace hyperdr;
FloatImage imageio(const std::vector<std::uint8_t>& bytes) {
  auto data=CFDataCreate(nullptr,bytes.data(),bytes.size());
  auto source=CGImageSourceCreateWithData(data,nullptr);CFRelease(data);
  const void* keys[]{kCGImageSourceDecodeRequest,kCGImageSourceGenerateImageSpecificLumaScaling,kCGImageSourceShouldCache};
  const void* values[]{kCGImageSourceDecodeToHDR,kCFBooleanFalse,kCFBooleanFalse};
  auto options=CFDictionaryCreate(nullptr,keys,values,3,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  auto image=CGImageSourceCreateImageAtIndex(source,0,options);CFRelease(options);CFRelease(source);
  if(!image)throw std::runtime_error("ImageIO decode failed");
  const auto w=CGImageGetWidth(image),h=CGImageGetHeight(image);
  std::cout<<"imageio_headroom="<<CGImageGetContentHeadroom(image)<<" ";
  std::vector<float> rgba(w*h*4);
  auto space=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
  auto ctx=CGBitmapContextCreate(rgba.data(),w,h,32,w*16,space,kCGImageAlphaPremultipliedLast|kCGBitmapFloatComponents|kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);if(!ctx)throw std::runtime_error("ImageIO context failed");
  CGContextSetEDRTargetHeadroom(ctx,0);CGContextSetInterpolationQuality(ctx,kCGInterpolationNone);
  CGContextDrawImage(ctx,CGRectMake(0,0,w,h),image);CGContextRelease(ctx);CGImageRelease(image);
  FloatImage result(w,h,3);
  for(std::size_t i=0;i<w*h;++i)for(unsigned c=0;c<3;++c)result.pixels[i*3+c]=rgba[i*4+c];
  const auto jpeg=inspect_gain_map_jpeg(bytes);
  for(const auto& app:jpeg.app_segments[0])if(app.marker==0xe1 && app.payload.size()>6 &&
      std::equal(app.payload.begin(),app.payload.begin()+6,"Exif\0\0")) {
    const auto exif=read_exif(app.payload.data()+6,app.payload.size()-6);
    result=apply_exif_orientation(std::move(result),exif.orientation.value_or(1));break;
  }
  return result;
}
struct Metrics { double mean,p99,max; };
Metrics metrics(const FloatImage& actual,const FloatImage& expected,const char* label) {
  if(actual.width!=expected.width||actual.height!=expected.height)throw std::runtime_error("comparison shape mismatch");
  std::vector<double> errors;errors.reserve(actual.pixels.size());
  double sum=0;std::size_t worst=0;
  for(std::size_t i=0;i<actual.pixels.size();++i){
    const auto e=std::abs(std::log2(std::max(actual.pixels[i],1e-6F)/std::max(expected.pixels[i],1e-6F)));
    if(!std::isfinite(e))throw std::runtime_error("nonfinite comparison");
    if(errors.empty()||e>errors[worst])worst=i;
    errors.push_back(e);sum+=e;
  }
  std::cout<<label<<" worst=("<<(worst/3)%actual.width<<","<<(worst/3)/actual.width<<","<<worst%3<<") ";
  std::sort(errors.begin(),errors.end());Metrics m{sum/errors.size(),errors[errors.size()*99/100],errors.back()};
  std::cout<<"mean="<<m.mean<<" p99="<<m.p99<<" max="<<m.max
      <<" candidate_at_max="<<actual.pixels[worst]<<" reference_at_max="<<expected.pixels[worst]<<"\n";return m;
}
int compare_imageio(const std::vector<std::uint8_t>& bytes) {
  auto candidate=codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);
  auto reference=codec::decode_legacy_ultrahdr_bytes(bytes,ColorGamut::kSrgb);
  auto third=imageio(bytes);
  (void)metrics(candidate.linear_p3,third,"candidate/imageio");
  (void)metrics(reference.linear_p3,third,"libultrahdr/imageio");
  auto luminance=[](const FloatImage& a,std::size_t i){return a.pixels[i]*.22897456+a.pixels[i+1]*.69173852+a.pixels[i+2]*.07928691;};
  auto filtered=[&](const FloatImage& value,const char* label,bool channels){
    std::vector<double> e;double sum=0;
    for(std::size_t i=0;i<third.pixels.size();i+=3) {
      if(channels){for(unsigned c=0;c<3;++c)if(value.pixels[i+c]>=.02 && third.pixels[i+c]>=.02){
        const double d=std::abs(std::log2(value.pixels[i+c]/third.pixels[i+c]));e.push_back(d);sum+=d;
      }}else if(luminance(*candidate.authored_sdr,i)>=.02){
        const double d=std::abs(std::log2(std::max(luminance(value,i),1e-6)/std::max(luminance(third,i),1e-6)));e.push_back(d);sum+=d;
      }
    }
    if(e.empty())throw std::runtime_error("empty filtered comparison");
    std::sort(e.begin(),e.end());Metrics m{sum/e.size(),e[e.size()*99/100],e.back()};
    std::cout<<label<<(channels?" filtered_RGB":" bright_Y")<<" count="<<e.size()<<" mean="<<m.mean<<" p99="<<m.p99<<"\n";return m;
  };
  const auto ownY=filtered(candidate.linear_p3,"candidate/imageio",false),oldY=filtered(reference.linear_p3,"libultrahdr/imageio",false);
  const auto ownC=filtered(candidate.linear_p3,"candidate/imageio",true),oldC=filtered(reference.linear_p3,"libultrahdr/imageio",true);
  const auto jpeg=parse_gain_map_jpeg_input(bytes);
  auto gain=codec::decode_jpeg_gain_bytes({bytes.begin()+jpeg.gain_offset,bytes.begin()+jpeg.gain_offset+jpeg.gain_size},gain_map_channel_count(jpeg.metadata));
  for(const auto& app:jpeg.app_segments[0])if(app.marker==0xe1 && app.payload.size()>6 &&
      std::equal(app.payload.begin(),app.payload.begin()+6,"Exif\0\0")) {
    const auto exif=read_exif(app.payload.data()+6,app.payload.size()-6);
    gain=apply_exif_orientation(std::move(gain),exif.orientation.value_or(1));break;
  }
  struct Bucket {std::size_t n=0,positive=0;double excess=0,signed_delta=0,own=0,old=0,own_signed=0,old_signed=0;};
  std::array<Bucket,5> buckets{};
  for(unsigned y=0;y<third.height;++y)for(unsigned x=0;x<third.width;++x){
    const auto i=(static_cast<std::size_t>(y)*third.width+x)*3;
    if(luminance(*candidate.authored_sdr,i)<.02)continue;
    const auto gx=std::min(gain.width-1,static_cast<unsigned>(static_cast<std::uint64_t>(x)*gain.width/third.width));
    const auto gy=std::min(gain.height-1,static_cast<unsigned>(static_cast<std::uint64_t>(y)*gain.height/third.height));
    float gradient=0;
    for(unsigned c=0;c<gain.channels;++c)for(int dy=-1;dy<=1;++dy)for(int dx=-1;dx<=1;++dx){
      const auto xx=std::clamp(int(gx)+dx,0,int(gain.width)-1),yy=std::clamp(int(gy)+dy,0,int(gain.height)-1);
      gradient=std::max(gradient,std::abs(gain.at(gx,gy,c)-gain.at(xx,yy,c))*255.F);
    }
    const auto bin=gradient<.5?0:gradient<=1.01?1:gradient<=4.01?2:gradient<=16.01?3:4;
    const auto a=std::log2(std::max(luminance(candidate.linear_p3,i),1e-6)/std::max(luminance(third,i),1e-6));
    const auto b=std::log2(std::max(luminance(reference.linear_p3,i),1e-6)/std::max(luminance(third,i),1e-6));
    auto& k=buckets[bin];++k.n;k.positive+=std::abs(a)>std::abs(b);k.excess+=std::abs(a)-std::abs(b);k.signed_delta+=a-b;k.own+=std::abs(a);k.old+=std::abs(b);k.own_signed+=a;k.old_signed+=b;
  }
  const char* labels[]{"flat_0","1_code","2_to_4_codes","5_to_16_codes","over_16_codes"};
  bool attribution=true;
  for(unsigned bin=0;bin<buckets.size();++bin){const auto& k=buckets[bin];if(!k.n)continue;
    const auto a=std::abs(k.own_signed/k.n),b=std::abs(k.old_signed/k.n);
    attribution &= a<=b || (a<=.003 && b<=.003);
    std::cout<<"gradient_bucket="<<labels[bin]<<" count="<<k.n<<" own_mean="<<k.own/k.n<<" old_mean="<<k.old/k.n
      <<" excess_mean="<<k.excess/k.n<<" signed_own_minus_old="<<k.signed_delta/k.n<<" own_imageio_signed_mean="<<k.own_signed/k.n<<" lib_imageio_signed_mean="<<k.old_signed/k.n<<" positive_excess_fraction="<<double(k.positive)/k.n<<"\n";
  }
  auto pass=[](Metrics own,Metrics old){return own.mean<=.02 && own.p99<=.1 && own.mean<=old.mean+.005 && own.p99<=old.p99+.02;};
  std::cout<<"gradient_attribution_pass="<<attribution<<"\n";
  return attribution&&pass(ownY,oldY)&&pass(ownC,oldC)?0:1;
}
void compare_metadata(const std::vector<std::uint8_t>& bytes) {
  const auto m=parse_gain_map_jpeg_input(bytes).metadata;
  auto* decoder=uhdr_create_decoder();
  struct Free{uhdr_codec_private_t* p;~Free(){uhdr_release_decoder(p);}} free{decoder};
  uhdr_compressed_image_t input{};input.data=const_cast<std::uint8_t*>(bytes.data());input.data_sz=input.capacity=bytes.size();
  if(uhdr_dec_set_image(decoder,&input).error_code || uhdr_dec_probe(decoder).error_code)throw std::runtime_error("reference metadata probe failed");
  const auto* g=uhdr_dec_get_gainmap_metadata(decoder);
  if(!g)throw std::runtime_error("reference gain metadata missing");
  double largest=0;
  auto check=[&](double a,double b){largest=std::max(largest,std::abs(a-b));};
  check(rational_value(m.base_headroom),std::log2(g->hdr_capacity_min));
  check(rational_value(m.alternate_headroom),std::log2(g->hdr_capacity_max));
  if(m.use_base_color_space!=bool(g->use_base_cg))throw std::runtime_error("gain working space differs");
  for(unsigned c=0;c<3;++c){auto k=gain_map_channel(m,gain_map_channel_count(m)==1?0:c);
    check(rational_value(k.gain_min),std::log2(g->min_content_boost[c]));
    check(rational_value(k.gain_max),std::log2(g->max_content_boost[c]));
    check(rational_value(k.gamma),g->gamma[c]);check(rational_value(k.base_offset),g->offset_sdr[c]);
    check(rational_value(k.alternate_offset),g->offset_hdr[c]);
  }
  std::cout<<"metadata_max_delta="<<largest<<"\n";
  if(largest>1e-4)throw std::runtime_error("ISO metadata tolerance exceeded");
}
bool compare(const std::vector<std::uint8_t>& bytes, const char* label, bool enforce=false) {
  compare_metadata(bytes);
  const auto expected = codec::decode_legacy_ultrahdr_bytes(bytes,ColorGamut::kSrgb);
  const auto actual = codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);
  if(expected.linear_p3.width!=actual.linear_p3.width || expected.linear_p3.height!=actual.linear_p3.height || expected.metadata.orientation!=actual.metadata.orientation)throw std::runtime_error("geometry differs");
  if(expected.authored_sdr->pixels != actual.authored_sdr->pixels) throw std::runtime_error("SDR differs");
  std::vector<double> errors;
  for (std::size_t i=0;i<expected.linear_p3.pixels.size();++i) {
    const double a=std::max(1e-6F,actual.linear_p3.pixels[i]);
    const double b=std::max(1e-6F,expected.linear_p3.pixels[i]);
    errors.push_back(std::abs(std::log2(a/b)));
  }
  const auto worst=static_cast<std::size_t>(std::max_element(errors.begin(),errors.end())-errors.begin());
  std::cout<<"worst=("<<(worst/3)%actual.linear_p3.width<<","<<(worst/3)/actual.linear_p3.width<<","<<worst%3<<") ";
  double sum=0;for(auto v:errors)sum+=v;
  std::sort(errors.begin(),errors.end());
  const auto mean=sum/errors.size(),p99=errors[errors.size()*99/100],max=errors.back();
  std::cout<<label<<" mean="<<mean<<" p99="<<p99<<" max="<<max<<'\n';
  return !enforce || (mean<=.005 && p99<=.02 && max<=.1);
}
void require(bool condition,const char* message){if(!condition)throw std::runtime_error(message);}
void regressions() {
  const auto root=std::filesystem::path(HYPERDR_TEST_FIXTURES);
  const auto original=read_binary_file(root/"iso-mono.jpg");
  const auto parsed=parse_gain_map_jpeg(original);
  auto stale=original;
  const auto& mpf=*std::find_if(parsed.app_segments[0].begin(),parsed.app_segments[0].end(),[](const auto& a){return a.marker==0xe2 && a.payload.size()>4 && a.payload[0]=='M';});
  // These fixtures have a big-endian MP entry table at TIFF + 50.
  const auto offset_at=mpf.offset+8+50+24;
  stale[offset_at+3]^=1;
  auto recovered=parse_gain_map_jpeg_input(stale);
  require(recovered.repaired_mpf,"stale MPF was not repaired");
  require(recovered.recorded_gain_offset!=recovered.gain_offset && recovered.entries[1].size==parsed.gain_size,"MPF recorded values were lost");
  auto trailer=stale;
  trailer.insert(trailer.end(),5,0);
  trailer.insert(trailer.end(),original.begin(),original.end());
  recovered=parse_gain_map_jpeg_input(trailer);
  require(recovered.trailing_bytes==original.size()+5,"opaque JPEG trailer was consumed");
  const auto path=std::filesystem::temp_directory_path()/("hyperdr-e4c-"+std::to_string(getpid())+".jpg");
  struct Remove { std::filesystem::path path;~Remove(){std::error_code e;std::filesystem::remove(path,e);} } cleanup{path};
  write_binary_file_atomic(path,trailer,true);
  const auto decoded=decode_image(path);
  require(decoded.domain==InputDomain::kDualRendition,"stale MPF HDR was lost");
  auto duplicate=original;
  const auto& iso=parsed.app_segments[1][0];
  duplicate.insert(duplicate.begin()+parsed.gain_offset+2,
      original.begin()+iso.offset,original.begin()+iso.offset+iso.payload.size()+4);
  write_binary_file_atomic(path,duplicate,true);
  auto fallback=decode_image(path);
  require(fallback.domain==InputDomain::kDisplayReferredSdr && fallback.decode.degraded,"duplicate ISO did not fall back to SDR");
  require(std::find(fallback.decode.degradation_reasons.begin(),fallback.decode.degradation_reasons.end(),"gain_map_metadata_duplicate")!=fallback.decode.degradation_reasons.end(),"duplicate ISO reason is missing");
  auto nongain=stale;
  nongain[iso.offset+4]='x';
  write_binary_file_atomic(path,nongain,true);
  fallback=decode_image(path);
  require(fallback.domain==InputDomain::kDisplayReferredSdr && fallback.decode.degraded,"non-gain alternate did not report SDR fallback");
  CancelToken token;token.request();CancelScope scope(&token);
  bool cancelled=false;try{(void)decode_image(path);}catch(const Cancelled&){cancelled=true;}
  require(cancelled,"JPEG cancellation was swallowed by SDR fallback");
}
void roundtrip() {
  for(unsigned ch:{1U,3U}) {
    GainMapResult p;p.base_linear=FloatImage(128,96,3);p.gain_map=FloatImage(64,48,ch);
    for(unsigned y=0;y<96;++y)for(unsigned x=0;x<128;++x)for(unsigned c=0;c<3;++c)p.base_linear.at(x,y,c)=.05F+.8F*float(x+y+c)/225;
    for(unsigned y=0;y<48;++y)for(unsigned x=0;x<64;++x)for(unsigned c=0;c<ch;++c)p.gain_map.at(x,y,c)=float(x+y+7*c)/130;
    p.metadata.gain_max={2,1};p.metadata.alternate_headroom={2,1};p.metadata.base_offset=p.metadata.alternate_offset={1,64};
    if(ch==3){p.metadata.flags|=0x80;p.metadata.channels.resize(3);for(unsigned c=0;c<3;++c)
      p.metadata.channels[c]={{-int(c),4},{int(c)+2,1},{int(c)+2,2},{int(c)+1,64},{int(c)+2,64}};}
    const auto source=reconstruct_gain_map(p.base_linear,p.gain_map,p.metadata,2);
    const auto bytes=encode_gain_map_jpeg(p,{},95);
    const auto own=codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);
    const auto old=codec::decode_legacy_ultrahdr_bytes(bytes,ColorGamut::kSrgb);
    auto errors=[&](const FloatImage& candidate,const FloatImage& reference) {
      std::vector<double> values;double sum=0;
      auto y=[](const FloatImage& a,std::size_t i){return a.pixels[i]*.22897456+a.pixels[i+1]*.69173852+a.pixels[i+2]*.07928691;};
      for(std::size_t i=0;i<reference.pixels.size();i+=3)if(y(p.base_linear,i)>=.02){auto e=std::abs(std::log2(std::max(y(candidate,i),1e-6)/std::max(y(reference,i),1e-6)));values.push_back(e);sum+=e;}
      std::sort(values.begin(),values.end());return std::pair(sum/values.size(),values[values.size()*99/100]);
    };
    const auto base=errors(*own.authored_sdr,p.base_linear),candidate=errors(own.linear_p3,source),legacy=errors(old.linear_p3,source);
    std::cout<<"roundtrip_channels="<<ch<<" own_extra_mean="<<candidate.first-base.first<<" own_extra_p99="<<candidate.second-base.second
        <<" legacy_extra_mean="<<legacy.first-base.first<<" legacy_extra_p99="<<legacy.second-base.second<<"\n";
    const auto peak=[](const FloatImage& image) {
      std::vector<float> peaks;peaks.reserve(image.width*image.height);
      for(std::size_t i=0;i<image.pixels.size();i+=3)
        peaks.push_back(std::max({image.pixels[i],image.pixels[i+1],image.pixels[i+2]}));
      const auto index=static_cast<std::size_t>(std::ceil(peaks.size()*.9999))-1;
      std::nth_element(peaks.begin(),peaks.begin()+index,peaks.end());return peaks[index];
    };
    const auto source_peak=peak(source);
    const double own_peak_error=std::abs(peak(own.linear_p3)/source_peak-1);
    const double legacy_peak_error=std::abs(peak(old.linear_p3)/source_peak-1);
    std::cout<<"roundtrip_channels="<<ch<<" own_peak_relative_error="<<own_peak_error
        <<" legacy_peak_relative_error="<<legacy_peak_error<<"\n";
    require(own_peak_error<=.02 && own_peak_error<=legacy_peak_error,"roundtrip p99.99 peak exceeded or is worse than libultrahdr");
    require(candidate.first-base.first<=.01 && candidate.second-base.second<=.04,"roundtrip E4 extra error exceeded");
    require(candidate.first<=legacy.first && candidate.second<=legacy.second,"roundtrip is worse than libultrahdr");
  }
}
// Request cancellation from the progress callback itself: this pins the gap
// inside jpeg_start_decompress rather than racing a small wall-clock delay.
thread_local CancelToken* progress_token=nullptr;
thread_local unsigned cancel_components=0;
thread_local bool cancelled_in_start=false;
void cancel_in_start(bool starting,unsigned components) noexcept {
  if(starting && components==cancel_components) {
    cancelled_in_start=true;progress_token->request();
  }
}
std::vector<std::uint8_t> synthetic_jpeg(unsigned width,unsigned height,unsigned components,bool progressive) {
  jpeg_compress_struct info{};jpeg_error_mgr error{};info.err=jpeg_std_error(&error);
  jpeg_create_compress(&info);unsigned char* output=nullptr;unsigned long size=0;
  jpeg_mem_dest(&info,&output,&size);info.image_width=width;info.image_height=height;
  info.input_components=components;info.in_color_space=components==1 ? JCS_GRAYSCALE : JCS_RGB;
  jpeg_set_defaults(&info);info.write_JFIF_header=FALSE;info.write_Adobe_marker=FALSE;jpeg_set_quality(&info,90,TRUE);
  if(progressive)jpeg_simple_progression(&info);
  jpeg_start_compress(&info,TRUE);std::vector<unsigned char> row(width*components);unsigned seed=321;
  while(info.next_scanline<height) {
    for(auto& v:row){seed=seed*1664525U+1013904223U;v=seed>>24;}
    JSAMPROW p=row.data();jpeg_write_scanlines(&info,&p,1);
  }
  jpeg_finish_compress(&info);std::vector<std::uint8_t> result(output,output+size);
  std::free(output);jpeg_destroy_compress(&info);return result;
}
void progressive_regressions() {
  GainMapMetadata metadata;metadata.gain_max=metadata.alternate_headroom={2,1};
  for(unsigned component:{3U,1U}) {
    const auto primary=synthetic_jpeg(128,96,3,component==3);
    const auto gain=synthetic_jpeg(64,48,1,component==1);
    const auto bytes=assemble_gain_map_jpeg(primary,gain,metadata);
    CancelToken token;progress_token=&token;cancel_components=component;cancelled_in_start=false;
    codec::testing::set_jpeg_progress_hook(cancel_in_start);
    bool cancelled=false;
    try {CancelScope scope(&token);(void)codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);}
    catch(const Cancelled&){cancelled=true;}
    codec::testing::set_jpeg_progress_hook(nullptr);progress_token=nullptr;
    require(cancelled && cancelled_in_start,"progressive JPEG startup did not propagate cancellation");
    const auto decoded=codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);
    require(decoded.linear_p3.width==128 && decoded.linear_p3.height==96,"decode after progressive cancellation failed");
  }
}
void cancel_progressive_large() {
  GainMapMetadata metadata;metadata.gain_max=metadata.alternate_headroom={2,1};
  for(unsigned component:{3U,1U}) {
    const auto large=synthetic_jpeg(10000,5000,component,true);
    std::vector<std::uint8_t> bytes;
    if(component==3)bytes=assemble_gain_map_jpeg(large,synthetic_jpeg(2,1,1,false),metadata);
    for(unsigned delay:{10U,100U,250U,500U}) {
      CancelToken token;bool cancelled=false;std::exception_ptr failure;
      std::thread worker([&]{try{CancelScope scope(&token);
        if(component==3)(void)codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);
        else (void)codec::decode_jpeg_gain_bytes(large,1);
      }catch(const Cancelled&){cancelled=true;}catch(...){failure=std::current_exception();}});
      std::this_thread::sleep_for(std::chrono::milliseconds(delay));const auto requested=std::chrono::steady_clock::now();
      token.request();worker.join();if(failure)std::rethrow_exception(failure);
      const double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-requested).count();
      std::cout<<"progressive_components="<<component<<" request_ms="<<delay<<" cancel_tail_ms="<<ms<<"\n";
      require(cancelled,"progressive large JPEG completed without observing cancellation");
      require(ms<=200,"progressive JPEG cancellation exceeded 200 ms");
    }
  }
}
void analytic() {
  FloatImage base(128,96,3),gain(32,24,1);
  std::fill(base.pixels.begin(),base.pixels.end(),.25F);
  for(unsigned y=0;y<24;++y)for(unsigned x=0;x<32;++x)gain.at(x,y,0)=float(x+y)/60;
  GainMapMetadata metadata;metadata.gain_max={2,1};metadata.alternate_headroom={2,1};
  const auto hdr=reconstruct_gain_map(base,gain,metadata,2);
  // At (40,40), legacy's origin hits gain(10,10) exactly (so its Shepard
  // kernel has weight 1). Pixel-centred bilinear hits (9.625,9.625).
  const double legacy=.25*std::exp2(2.*20./60.);
  const double delta=std::log2(legacy/hdr.at(40,40,0));
  std::cout<<"analytic_ramp expected_delta=.025 measured_delta="<<delta<<"\n";
  require(std::abs(delta-.025)<1e-6,"pixel-centre ramp prediction failed");
}
void cancel_large() {
  GainMapResult pair;pair.base_linear=FloatImage(10000,5000,3);pair.gain_map=FloatImage(2,1,1);
  std::fill(pair.base_linear.pixels.begin(),pair.base_linear.pixels.end(),.25F);
  std::fill(pair.gain_map.pixels.begin(),pair.gain_map.pixels.end(),.6F);pair.metadata.gain_max={2,1};pair.metadata.alternate_headroom={2,1};
  const auto bytes=encode_gain_map_jpeg(pair,{},90);pair={};
  CancelToken token;bool cancelled=false;
  std::thread worker([&]{CancelScope scope(&token);try{(void)codec::decode_iso_gain_map_jpeg_bytes(bytes,ColorGamut::kSrgb);}catch(const Cancelled&){cancelled=true;}});
  std::this_thread::sleep_for(std::chrono::milliseconds(10));const auto requested=std::chrono::steady_clock::now();token.request();worker.join();
  const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-requested).count();
  std::cout<<"50MP_ISO_decode_cancel_ms="<<ms<<"\n";
  require(cancelled,"50 MP decode did not propagate cancellation");
  require(ms<=200,"50 MP decode cancellation exceeded 200 ms");
}
int main(int argc,char**argv) {
  try {
    if(argc==2 && std::string(argv[1])=="cancel-progressive"){cancel_progressive_large();return 0;}
    if(argc==2 && std::string(argv[1])=="cancel-large"){cancel_large();return 0;}
    if(argc==4 && std::string(argv[2])=="reexport") {
      auto input=codec::decode_legacy_ultrahdr_bytes(read_binary_file(argv[1]),ColorGamut::kSrgb);
      PhotoRenditions pair;pair.sdr=std::move(*input.authored_sdr);pair.hdr=std::move(input.linear_p3);
      pair.dual_rendition=true;pair.hdr_is_source=true;pair.authored_gain_channels=input.gain_map.channels;
      pair.authored_gain_map=input.gain_map;pair.fixed_gain_channels=true;
      // Re-export this source at a two-stop target so the independent
      // ImageIO comparison cannot invoke its >3-stop Adaptive Gain Curve.
      for(std::size_t i=0;i<pair.hdr.pixels.size();i+=3) {
        const float peak=std::max({pair.hdr.pixels[i],pair.hdr.pixels[i+1],pair.hdr.pixels[i+2],4.F});
        for(unsigned c=0;c<3;++c)pair.hdr.pixels[i+c]*=4.F/peak;
      }
      pair.stats.headroom_stops=2;pair.authored_gain_map.alternate_headroom=4;
      write_binary_file_atomic(argv[3],encode_gain_map_jpeg(gain_map_from_renditions(std::move(pair),GainMapWriterProfile::iso_generic),input.metadata,95),true);
      return 0;
    }
    if(argc==4 && std::string(argv[2])=="legacy-pair") {
      const auto a=codec::decode_legacy_ultrahdr_bytes(read_binary_file(argv[1]),ColorGamut::kSrgb);
      const auto b=codec::decode_legacy_ultrahdr_bytes(read_binary_file(argv[3]),ColorGamut::kSrgb);
      const bool hdr=a.linear_p3.pixels==b.linear_p3.pixels,sdr=a.authored_sdr->pixels==b.authored_sdr->pixels;
      std::cout<<"legacy_hdr_exact="<<hdr<<" legacy_sdr_exact="<<sdr<<"\n";return hdr&&sdr?0:1;
    }
    if(argc>2)return compare_imageio(read_binary_file(argv[1]));
    if(argc>1){return compare(read_binary_file(argv[1]),argv[1])?0:1;}
    regressions();progressive_regressions();analytic();roundtrip();
    bool passed=true;
    for(unsigned c:{1U,3U}) for(unsigned pattern:{0U,1U,2U}) {
      GainMapResult pair;
      pair.base_linear=FloatImage(128,96,3);
      pair.gain_map=FloatImage(32,24,c);
      for(unsigned y=0;y<96;++y)for(unsigned x=0;x<128;++x)for(unsigned k=0;k<3;++k)
        pair.base_linear.at(x,y,k)=.25F;
      for(unsigned y=0;y<24;++y)for(unsigned x=0;x<32;++x)for(unsigned k=0;k<c;++k)
        pair.gain_map.at(x,y,k)=pattern==0 ? .6F : pattern==1 ? static_cast<float>(x+y+k)/60 : static_cast<float>((x*7+y*13+k*29)%256)/255;
      pair.metadata.alternate_headroom={2,1};pair.metadata.gain_max={2,1};
      if(c==3){pair.metadata.flags|=0x80;pair.metadata.channels.resize(3);
        for(auto& m:pair.metadata.channels)m.gain_max={2,1};}
      std::cout<<"channels="<<c<<" pattern="<<pattern<<" ";
      passed=compare(encode_gain_map_jpeg(pair,{},95),"synthetic",pattern==0)&&passed;
    }
    return passed?0:1;
  }catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}

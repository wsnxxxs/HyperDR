#include "internal/gain_map_jpeg.hpp"
#include "internal/decode_bytes.hpp"
#include <algorithm>
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "../../../tests/support/writer_planes.hpp"
#include <ImageIO/ImageIO.h>
#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>
#include <pthread.h>
#include <exception>
using namespace hyperdr;
namespace {
void require(bool value,const char* message) {if(!value)throw std::runtime_error(message);}
thread_local CancelToken* cancel_hook;
std::atomic<bool> auxiliary_started{};
void cancel_before(bool before) noexcept {if(before)cancel_hook->request();}
void mark_before(bool before) noexcept {if(before)auxiliary_started=true;}
std::vector<std::uint8_t> late_mpf(const std::vector<std::uint8_t>& bytes) {
  const auto layout=inspect_gain_map_jpeg(bytes);
  const auto& apps=layout.app_segments[0];
  const auto it=std::find_if(apps.begin(),apps.end(),[](const auto& a){return a.marker==0xe2 && a.payload.size()>4 && std::equal(a.payload.begin(),a.payload.begin()+4,"MPF\0");});
  const auto old=it->offset,length=it->payload.size()+4,q=layout.first_dqt_offset;
  const auto after=q+2+(std::size_t(bytes[q+2])<<8)+bytes[q+3];
  require(old+length<=q,"fixture MPF layout changed");
  const auto at=after-length;
  auto result=bytes;
  result.erase(result.begin()+old,result.begin()+old+length);
  result.insert(result.begin()+at,bytes.begin()+old,bytes.begin()+old+length);
  const bool le=it->payload[4]=='I';
  auto read=[&](size_t p,unsigned n){std::uint32_t v=0;for(unsigned i=0;i<n;++i)v=(v<<8)|it->payload[4+p+(le?n-1-i:i)];return v;};
  const auto ifd=read(4,4),count=read(ifd,2);
  for(unsigned i=0;i<count;++i){const auto entry=ifd+2+12*i;if(read(entry,2)!=0xb002)continue;
    const auto table=read(entry+8,4);
    const auto offset=layout.entries[1].offset-(at-old);
    for(unsigned j=0;j<4;++j)result[at+8+table+24+j]=offset>>(8*(le?j:3-j));
  }
  return result;
}
void regressions() {
  const auto path=std::filesystem::path(HYPERDR_TEST_FIXTURES)/"xmp-only.jpg";
  const auto bytes=read_binary_file(path);
  require(normalize_gain_map_jpeg_mpf(bytes).empty(),"early MPF unexpectedly copied");
  const auto late=late_mpf(bytes),normalized=normalize_gain_map_jpeg_mpf(late);
  require(inspect_gain_map_jpeg(late).mpf_after_dqt,"late MPF variant not late");
  require(!inspect_gain_map_jpeg(normalized).mpf_after_dqt && normalize_gain_map_jpeg_mpf(normalized).empty(),"MPF normalization not idempotent");
  auto data=CFDataCreate(nullptr,late.data(),late.size());
  auto source=CGImageSourceCreateWithData(data,nullptr);CFRelease(data);
  auto auxiliary=CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap);CFRelease(source);
  std::cout<<"unnormalized_late_MPF_auxiliary="<<bool(auxiliary)<<"\n";
  if(auxiliary)CFRelease(auxiliary);
  const auto input=codec::read_gain_map_jpeg_imageio(bytes);
  require(input.pixels.width==64 && input.pixels.height==48 && input.pixels.channels==1,"auxiliary geometry");
  require(input.metadata.alternate_headroom.numerator==2000000 && input.metadata.alternate_headroom.denominator==1000000,"ImageIO rationalization must round to six decimal places");
  const auto actual=codec::read_gain_map_jpeg_imageio(late);
  require(actual.pixels.pixels==input.pixels.pixels,"late MPF auxiliary differs");
  const auto original=codec::decode_ultrahdr_bytes(bytes,ColorGamut::kSrgb);
  for(const auto& sample:{bytes,late}) {
    const auto result=codec::decode_ultrahdr_bytes(sample,ColorGamut::kSrgb);
    require(result.linear_p3.pixels==original.linear_p3.pixels && result.authored_sdr->pixels==original.authored_sdr->pixels,"XMP repeated decode not exact");
  }
  CancelToken token;CancelScope scope(&token);cancel_hook=&token;
  codec::testing::set_imageio_gain_map_hook(cancel_before);
  bool cancelled=false;
  try{(void)codec::read_gain_map_jpeg_imageio(late);}catch(const Cancelled&){cancelled=true;}
  codec::testing::set_imageio_gain_map_hook(nullptr);
  require(cancelled,"auxiliary cancellation was lost");
}
void large_iso(const char* path) {
  GainMapResult pair;pair.base_linear=FloatImage(10000,5000,3);pair.gain_map=FloatImage(5000,2500,1);
  std::fill(pair.base_linear.pixels.begin(),pair.base_linear.pixels.end(),.25F);
  for(unsigned y=0;y<pair.gain_map.height;++y)for(unsigned x=0;x<pair.gain_map.width;++x)
    pair.gain_map.at(x,y,0)=float((x*73+y*37+(x*y)%251)%256)/255;
  pair.metadata.gain_max={2,1};pair.metadata.alternate_headroom={2,1};
  write_binary_file_atomic(path,encode_gain_map_jpeg(pair,{},95),true);
}
void cancel_large(const char* path) {
  const auto bytes=read_binary_file(path);
  for(unsigned delay:{1U,10U,25U}) {
    auxiliary_started=false;CancelToken token;std::atomic<bool> done{};bool cancelled=false;std::exception_ptr failure;
    std::thread worker([&]{CancelScope scope(&token);codec::testing::set_imageio_gain_map_hook(mark_before);
      try{(void)codec::read_gain_map_jpeg_imageio(bytes);}catch(const Cancelled&){cancelled=true;}catch(...){failure=std::current_exception();}
      codec::testing::set_imageio_gain_map_hook(nullptr);done=true;});
    while(!auxiliary_started && !done)std::this_thread::yield();
    std::this_thread::sleep_for(std::chrono::milliseconds(delay));
    const auto start=std::chrono::steady_clock::now();token.request();worker.join();
    if(failure)std::rethrow_exception(failure);
    const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    std::cout<<"50MP_XMP_auxiliary_cancel request_ms="<<delay<<" tail_ms="<<ms<<" cancelled="<<cancelled<<"\n";
    require(cancelled,"large auxiliary completed before cancellation");require(ms<=200,"ImageIO auxiliary cancellation exceeds 200 ms");
  }
}
}
int main(int argc,char**argv) {
  try {
    if(argc==3 && std::string(argv[1])=="large-iso")large_iso(argv[2]);
    else if(argc==3 && std::string(argv[1])=="cancel-large")cancel_large(argv[2]);
    else {
      std::exception_ptr failure;
      pthread_attr_t attributes;
      require(pthread_attr_init(&attributes)==0,"pthread attributes");
      require(pthread_attr_setstacksize(&attributes,512*1024)==0,"512 KB stack unavailable");
      pthread_t worker;
      const int status=pthread_create(&worker,&attributes,[](void* context)->void* {
        try { regressions(); } catch(...) { *static_cast<std::exception_ptr*>(context)=std::current_exception(); }
        return nullptr;
      },&failure);
      pthread_attr_destroy(&attributes);
      require(status==0,"ImageIO 512 KB thread creation failed");
      require(pthread_join(worker,nullptr)==0,"ImageIO 512 KB thread join failed");
      if(failure)std::rethrow_exception(failure);
      std::cout<<"ImageIO cold 512 KB stack, MPF placement, rationalization, repetition and cancellation passed\n";
    }
    return 0;
  }catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
}

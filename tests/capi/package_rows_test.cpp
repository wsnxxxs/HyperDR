#include "hyperdr/hyperdr.h"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include <avif/avif.h>
#include <array>
#include <memory>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <unistd.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <signal.h>

#define REQUIRE(x) do { if(!(x))throw std::runtime_error(#x); } while(0)
struct Source {
  unsigned width=65,height=533,channels=1;
  bool frame=false,fail=false,cancel=false;
  float gain_scale=1.f, gain_bias=0.f;
  hyperdr_cancel* token=nullptr;
  unsigned largest=0, reads=0;
  std::vector<std::array<uint32_t,3>> progress_events;
  static void progress(void* context,uint32_t phase,uint32_t done,uint32_t total) {
    static_cast<Source*>(context)->progress_events.push_back({phase,done,total});
  }
  static float gain_scale_value(const Source& s,float u,float v,unsigned c) {
    return s.gain_bias+s.gain_scale*((s.channels==3?-.3f:0.f)+1.8f*u*v*(1-.1f*float(c)));
  }
  static int read(void* context,unsigned y,unsigned count,float* base,float* gain) {
    auto& s=*static_cast<Source*>(context);s.largest=std::max(s.largest,count);
    ++s.reads;
    if(s.fail)return 1;
    if(s.cancel)hyperdr_cancel_request(s.token);
    for(unsigned row=0;row<count;++row)for(unsigned x=0;x<s.width;++x) {
      const auto i=std::size_t(row)*s.width+x;
      const auto u=float(x)/float(s.width-1),v=float(y+row)/float(s.height-1);
      base[i*3]=.1f+.7f*u;base[i*3+1]=.1f+.6f*v;base[i*3+2]=.15f;
      if(gain)for(unsigned c=0;c<s.channels;++c)
        gain[i*s.channels+c]=s.frame&&(x<16||x>=s.width-16||y+row<16||y+row>=s.height-16)?0.f:
            gain_scale_value(s,u,v,c);
    }
    return 0;
  }
};
void status(int code,char* report,hyperdr_error* error) {
  if(code) {
    const std::string message=error?std::string(error->code)+": "+error->message:"missing error";
    hyperdr_error_free(error);hyperdr_string_free(report);throw std::runtime_error(message);
  }
  REQUIRE(report&&std::strstr(report,"hyperdr.package/v1"));
  hyperdr_string_free(report);hyperdr_error_free(error);
}
void footprint(const char* stage) {
  task_vm_info_data_t vm{};mach_msg_type_number_t n=sizeof(vm)/sizeof(integer_t);
  if(task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&vm),&n)==KERN_SUCCESS)
    std::cout<<"PACKAGE_MEMORY "<<stage<<" footprint="<<vm.phys_footprint<<" peak="<<vm.ledger_phys_footprint_peak<<'\n';
}
// Native-code comparison avoids mistaking an HDR endpoint change for a
// floating-point decoder conversion difference or an independent grid seam.
struct AvifCodes {
  std::vector<std::uint16_t> rgb;
  unsigned cll=0,pall=0;
};
AvifCodes avif_codes(const std::vector<std::uint8_t>& bytes,unsigned width,unsigned height,bool pq) {
  std::unique_ptr<avifDecoder,decltype(&avifDecoderDestroy)> decoder(avifDecoderCreate(),&avifDecoderDestroy);
  REQUIRE(decoder);decoder->maxThreads=1;
  REQUIRE(avifDecoderSetIOMemory(decoder.get(),bytes.data(),bytes.size())==AVIF_RESULT_OK);
  REQUIRE(avifDecoderParse(decoder.get())==AVIF_RESULT_OK&&avifDecoderNextImage(decoder.get())==AVIF_RESULT_OK);
  const auto* image=decoder->image;
  REQUIRE(image&&image->width==width&&image->height==height&&image->depth==10&&image->yuvFormat==AVIF_PIXEL_FORMAT_YUV444);
  REQUIRE(image->colorPrimaries==AVIF_COLOR_PRIMARIES_BT2020&&image->matrixCoefficients==AVIF_MATRIX_COEFFICIENTS_BT2020_NCL&&image->yuvRange==AVIF_RANGE_FULL);
  REQUIRE(image->transferCharacteristics==(pq?AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084:AVIF_TRANSFER_CHARACTERISTICS_HLG));
  REQUIRE(image->exif.size&&image->xmp.size);
  avifRGBImage rgb{};avifRGBImageSetDefaults(&rgb,image);rgb.format=AVIF_RGB_FORMAT_RGB;rgb.depth=10;
  REQUIRE(avifRGBImageAllocatePixels(&rgb)==AVIF_RESULT_OK);
  struct Guard { avifRGBImage* rgb;~Guard(){avifRGBImageFreePixels(rgb);} } guard{&rgb};
  REQUIRE(avifImageYUVToRGB(image,&rgb)==AVIF_RESULT_OK);
  AvifCodes result;result.rgb.resize(std::size_t(width)*height*3);
  result.cll=image->clli.maxCLL;result.pall=image->clli.maxPALL;
  for(unsigned y=0;y<height;++y)std::memcpy(result.rgb.data()+std::size_t(y)*width*3,rgb.pixels+std::size_t(y)*rgb.rowBytes,width*6);
  return result;
}

int main(int argc,char** argv) try {
  if(argc>3&&std::string(argv[1])=="check") {
    footprint("before");
    const auto verified=hyperdr::verify_encoded_file(argv[2],*hyperdr::hdr_encoding_from_name(argv[3]));
    REQUIRE(verified.boundedMemory&&verified.pixels==std::uint64_t(verified.width)*verified.height);
    footprint("after");return 0;
  }
  auto directory=(std::filesystem::temp_directory_path()/"hyperdr-package-rows-XXXXXX").native();
  REQUIRE(mkdtemp(directory.data()));
  const std::filesystem::path root(directory);
  hyperdr_engine* engine=nullptr;hyperdr_error* error=nullptr;
  REQUIRE(hyperdr_engine_create(nullptr,&engine,&error)==0);
  Source source;
  const bool probe=argc>1;
  if(probe) { source.width=argc>6?unsigned(std::stoul(argv[6])):2048;source.height=argc>2?unsigned(std::stoul(argv[2])):2048; }
  hyperdr_package_plane base{};base.width=source.width;base.height=source.height;base.channels=3;base.format=HYPERDR_PLANE_F32;
  hyperdr_package_gain gain{};gain.plane=base;gain.plane.channels=1;gain.alternate_headroom=2;gain.working_gamut="display-p3";
  hyperdr_package_request request{};request.sdr=&base;request.gain=&gain;
  const auto parameters=probe?std::string("{\"quality\":93,\"verify\":")+(std::string(argv[1])=="verify"?"true}":"false}"):std::string("{\"quality\":93}");
  request.parameters_json=parameters.c_str();
  const auto whole=root/"whole",stream=root/"stream";
  const auto whole_path=whole.string(),stream_path=probe&&argc>5?std::string(argv[5]):stream.string();
  if(probe) {
    const unsigned rows=argc>3?unsigned(std::stoul(argv[3])):64;
    request.format=argc>4?argv[4]:"sdr-tiff";
    request.gain=std::string(request.format).starts_with("sdr-")?nullptr:&gain;
    // Include native E5 readback in gain-map probes.
    source.frame=request.gain!=nullptr&&!std::string(request.format).starts_with("avif-");
    request.presentation_frame=source.frame;request.has_frame_photo=source.frame;
    request.frame_photo={16,16,source.width-32,source.height-32};
    request.output_path=stream_path.c_str();
    footprint("before");char* report=nullptr;
    std::vector<float> plane;
    if(std::string(argv[1])=="full") {
      plane.resize(std::size_t(source.width)*source.height*3);
      Source::read(&source,0,source.height,plane.data(),nullptr);
      base.data=plane.data();base.size=plane.size()*sizeof(float);
      const auto code=hyperdr_package(engine,&request,&report,&error);status(code,report,error);
    } else {
      const auto code=hyperdr_package_rows(engine,&request,rows,Source::read,&source,&report,&error);status(code,report,error);
    }
    footprint("after");if(std::string(argv[1])!="full")REQUIRE(source.largest<=rows);
    std::filesystem::remove_all(root);hyperdr_engine_destroy(engine);return 0;
  }
  // The last strip/IFD can fail after all scanlines succeeded. No verification
  // may be needed to detect this, and KEEP must survive every writer failure.
  source.width=source.height=16;base.width=base.height=16;gain.plane.width=gain.plane.height=16;
  for(const char* format:{"sdr-tiff","sdr-jpeg","iso-gainmap-jpeg","adaptive","avif-pq","avif-hlg"}) {
    hyperdr::write_text_file_atomic(stream,"KEEP",false);
    request.format=format;request.output_path=stream_path.c_str();
    request.parameters_json="{\"verify\":false,\"overwrite\":true}";
    request.gain=std::string(format).starts_with("sdr-")?nullptr:&gain;
    struct rlimit original{};REQUIRE(getrlimit(RLIMIT_FSIZE,&original)==0);
    auto limited=original;limited.rlim_cur=128;
    auto previous=signal(SIGXFSZ,SIG_IGN);
    REQUIRE(setrlimit(RLIMIT_FSIZE,&limited)==0);
    char* report=nullptr;error=nullptr;
    const auto code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);
    REQUIRE(setrlimit(RLIMIT_FSIZE,&original)==0);signal(SIGXFSZ,previous);
    REQUIRE(code!=0);hyperdr_error_free(error);hyperdr_string_free(report);
    REQUIRE(hyperdr::read_binary_file(stream)==std::vector<std::uint8_t>({'K','E','E','P'}));
    std::filesystem::remove(stream);
  }
  source.width=base.width=gain.plane.width=65;source.height=base.height=gain.plane.height=533;
  request.parameters_json="{\"quality\":93}";
  REQUIRE(hyperdr_package_rows_supported("avif-pq")&&hyperdr_package_rows_supported("avif-hlg"));
  // AVIF uses disk-staged independent cells, not the all-YUV AddImageGrid API.
  // Verify its C ABI dispatch, single render pass count, dimensions and
  // bounded readback for both transfers and scalar/RGB gain.
  for(const char* format:{"avif-pq","avif-hlg"})for(unsigned channels:{1U,3U}) {
    source.channels=gain.plane.channels=channels;
    source.frame=false;request.presentation_frame=0;request.has_frame_photo=0;
    request.format=format;request.gain=&gain;request.output_path=stream_path.c_str();
    source.reads=0;source.largest=0;char* report=nullptr;error=nullptr;
    const auto code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);status(code,report,error);
    REQUIRE(source.largest<=13&&source.reads==((source.height+12)/13));
    const auto encoding=*hyperdr::hdr_encoding_from_name(format);
    const auto verified=hyperdr::verify_encoded_file(stream,encoding);
    REQUIRE(verified.boundedMemory&&verified.width==source.width&&verified.height==source.height&&verified.pixels==std::uint64_t(source.width)*source.height);
    const auto bytes=hyperdr::read_binary_file(stream);
    hyperdr::verify_encoded_output(bytes,encoding);
    auto broken=bytes;broken.resize(broken.size()/2);
    bool rejected=false;try{(void)hyperdr::verify_avif_pixels(broken);}catch(const std::exception&){rejected=true;}
    REQUIRE(rejected);
    std::filesystem::remove(stream);
  }
  // The progress entry reports every AVIF grid cell's encode and check (the
  // check runs beside the next encode), never backwards; other formats report
  // nothing, and the plain entry stays the same call without a callback.
  {
    source.width=base.width=gain.plane.width=2100;source.height=base.height=gain.plane.height=1100;
    source.channels=gain.plane.channels=1;source.frame=false;request.presentation_frame=0;request.has_frame_photo=0;
    for(const char* format:{"avif-pq","sdr-jpeg"}) {
      request.format=format;request.gain=std::string(format).starts_with("sdr-")?nullptr:&gain;
      request.output_path=stream_path.c_str();request.parameters_json="{\"quality\":60,\"overwrite\":true}";
      source.progress_events.clear();char* report=nullptr;error=nullptr;
      const auto code=hyperdr_package_rows_progress(engine,&request,64,Source::read,Source::progress,&source,&report,&error);
      status(code,report,error);
      if(std::string(format)=="sdr-jpeg") { REQUIRE(source.progress_events.empty()); continue; }
      uint32_t encoded=0,verified=0;
      for(const auto& [phase,done,total]:source.progress_events) {
        REQUIRE(total==6&&(phase==HYPERDR_PACKAGE_PHASE_ENCODE||phase==HYPERDR_PACKAGE_PHASE_VERIFY));
        auto& counter=phase==HYPERDR_PACKAGE_PHASE_ENCODE?encoded:verified;
        REQUIRE(done>=counter&&done<=total);counter=done;REQUIRE(verified<=encoded);
      }
      REQUIRE(encoded==6&&verified==6);
      const auto verified_file=hyperdr::verify_encoded_file(stream,*hyperdr::hdr_encoding_from_name(format));
      REQUIRE(verified_file.width==2100&&verified_file.height==1100);
    }
    std::filesystem::remove(stream);
    source.width=base.width=gain.plane.width=65;source.height=base.height=gain.plane.height=533;
    request.parameters_json="{\"quality\":93}";
  }
  // AVIF must keep whole-plane's 8-bit gain-code quantization, not HEIC's
  // continuous-code rule. Use exact one-cell dimensions to exclude grid seams;
  // >65536 scalar samples (and RGB samples) also pin the stratified gamma scan.
  source.width=base.width=gain.plane.width=128;
  source.height=base.height=gain.plane.height=576;
  request.parameters_json="{\"quality\":100}";
  for(const char* format:{"avif-pq","avif-hlg"})for(unsigned channels:{1U,3U})for(bool wide:{false,true})for(bool framed:{false,true}) {
    const bool pq=std::string(format)=="avif-pq";
    source.channels=gain.plane.channels=channels;source.frame=false;
    source.gain_scale=wide&&pq?4.f:1.f;source.gain_bias=-.4f;
    gain.base_headroom=0;gain.alternate_headroom=wide&&pq?8.f:2.f;
    for(unsigned c=0;c<3;++c) {
      gain.base_offset[c]=channels==3&&c==1?-.002f:.01f+.002f*float(channels==3?c:0);
      gain.alternate_offset[c]=channels==3&&c==1?-.003f:.02f+.003f*float(channels==3?c:0);
    }
    // Exercise the framed codebook's no-dither rule too, without a frame rect
    // (an AVIF has no stored gain map). Equal offsets satisfy the E5 contract.
    request.presentation_frame=framed;request.has_frame_photo=0;
    if(framed)for(unsigned c=0;c<3;++c)gain.alternate_offset[c]=gain.base_offset[c];
    std::vector<float> b(std::size_t(source.width)*source.height*3),g(std::size_t(source.width)*source.height*channels);
    Source::read(&source,0,source.height,b.data(),g.data());
    base.data=b.data();base.size=b.size()*sizeof(float);gain.plane.data=g.data();gain.plane.size=g.size()*sizeof(float);
    request.format=format;request.gain=&gain;request.output_path=whole_path.c_str();
    char* report=nullptr;error=nullptr;
    auto code=hyperdr_package(engine,&request,&report,&error);
    const std::string whole_report=report?report:"";status(code,report,error);
    request.output_path=stream_path.c_str();report=nullptr;error=nullptr;source.reads=0;source.largest=0;
    code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);
    const std::string row_report=report?report:"";status(code,report,error);
    REQUIRE(source.largest<=13&&source.reads==((source.height+12)/13));
    const auto ga=whole_report.find("\"gain\":");const auto gb=row_report.find("\"gain\":");
    REQUIRE(ga!=std::string::npos&&gb!=std::string::npos&&whole_report.substr(ga)==row_report.substr(gb));
    const auto parsed=hyperdr::json::parse(row_report);const auto* metadata=parsed.find("gain");
    REQUIRE(metadata&&!metadata->find("stored")->boolean()&&metadata->find("channels")->number()==channels);
    REQUIRE(metadata->find("gainMin")->number()<0&&metadata->find("gainMax")->number()>0);
    REQUIRE(metadata->find("alternateHeadroom")->number()==gain.alternate_headroom);
    REQUIRE(parsed.find("metadata")->find("icc")->string()=="rec2020");
    for(unsigned c=0;c<channels;++c) {
      REQUIRE(std::abs(metadata->find("baseOffsets")->array().at(c).number()-gain.base_offset[c])<1e-6);
      REQUIRE(std::abs(metadata->find("alternateOffsets")->array().at(c).number()-gain.alternate_offset[c])<1e-6);
    }
    const auto a=hyperdr::read_binary_file(whole),r=hyperdr::read_binary_file(stream);
    const auto ca=avif_codes(a,source.width,source.height,pq),cr=avif_codes(r,source.width,source.height,pq);
    REQUIRE(ca.cll==cr.cll&&ca.pall==cr.pall);
    int largest=0;for(std::size_t i=0;i<ca.rgb.size();++i)largest=std::max(largest,std::abs(int(ca.rgb[i])-int(cr.rgb[i])));
    REQUIRE(largest<=1); // No seam excuse: one identically sized 10-bit cell.
    const auto fa=hyperdr::read_heif(a),fr=hyperdr::read_heif(r);
    REQUIRE(fa.exif()==fr.exif()&&fa.xmp()==fr.xmp());
    std::filesystem::remove(whole);std::filesystem::remove(stream);
  }
  source.width=base.width=gain.plane.width=65;source.height=base.height=gain.plane.height=533;
  source.gain_scale=1.f;source.gain_bias=0;gain.base_headroom=0;gain.alternate_headroom=2;
  request.parameters_json="{\"quality\":93}";
  for(const char* format:{"sdr-tiff","sdr-jpeg","iso-gainmap-jpeg","adaptive","pq","hlg"}) {
    REQUIRE(hyperdr_package_rows_supported(format));
    source.channels=std::string(format)=="iso-gainmap-jpeg"?3:1;
    source.frame=std::string(format)=="iso-gainmap-jpeg"||std::string(format)=="adaptive";
    gain.plane.channels=source.channels;request.presentation_frame=source.frame;request.has_frame_photo=source.frame;
    request.frame_photo={16,16,source.width-32,source.height-32};
    for(unsigned c=0;c<3;++c) {gain.base_offset[c]=source.frame?1.f/64:0.f;gain.alternate_offset[c]=source.frame?1.f/64:0.f;}
    std::vector<float> b(std::size_t(source.width)*source.height*3),g(std::size_t(source.width)*source.height*source.channels);
    Source::read(&source,0,source.height,b.data(),g.data());source.largest=0;
    base.data=b.data();base.size=b.size()*4;gain.plane.data=g.data();gain.plane.size=g.size()*4;
    request.format=format;request.gain=std::string(format).starts_with("sdr-")?nullptr:&gain;
    request.output_path=whole_path.c_str();char* report=nullptr;error=nullptr;
    auto code=hyperdr_package(engine,&request,&report,&error);status(code,report,error);
    request.output_path=stream_path.c_str();report=nullptr;error=nullptr;
    source.reads=0;
    code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);status(code,report,error);
    REQUIRE(source.largest<=13);
    // Statistics, both pictures and CLLI share one caller render/read pass.
    REQUIRE(source.reads==((source.height+12)/13));
    const auto a=hyperdr::read_binary_file(whole),bbytes=hyperdr::read_binary_file(stream);
    const auto encoding=*hyperdr::hdr_encoding_from_name(format);
    const auto verified=hyperdr::verify_encoded_file(stream,encoding);
    REQUIRE(verified.boundedMemory&&verified.pixels==std::uint64_t(source.width)*source.height);
    // Original byte verifier and the new native-row/tile verifier agree on
    // valid files; a truncated codestream must fail both.
    hyperdr::verify_encoded_output(bbytes,encoding);
    if(std::string(format)=="iso-gainmap-jpeg" || std::string(format)=="adaptive") {
      // Change only the exported IFD0 orientation, keeping all pixel/container
      // bytes intact. E5 must reject a nonidentity display direction.
      std::vector<std::uint8_t> exif;
      if(encoding==hyperdr::OutputEncoding::Adaptive)exif=hyperdr::read_heif(bbytes).exif();
      else {
        const auto jpeg=hyperdr::parse_gain_map_jpeg(bbytes);
        for(const auto& app:jpeg.app_segments[0])
          if(app.marker==0xe1&&app.payload.size()>6&&!std::memcmp(app.payload.data(),"Exif\0\0",6))
            exif.assign(app.payload.begin()+6,app.payload.end());
      }
      REQUIRE(!exif.empty()&&hyperdr::read_exif_orientation(exif.data(),exif.size()).value_or(0)==1);
      const std::vector<std::uint8_t> tag{0x12,0x01,3,0,1,0,0,0,1,0,0,0};
      const auto entry=std::search(exif.begin(),exif.end(),tag.begin(),tag.end());
      REQUIRE(entry!=exif.end());
      const auto payload=std::search(bbytes.begin(),bbytes.end(),exif.begin(),exif.end());
      REQUIRE(payload!=bbytes.end());
      auto rotated=bbytes;
      rotated[std::size_t(payload-bbytes.begin())+std::size_t(entry-exif.begin())+8]=6;
      const auto broken=root/"rotated";hyperdr::write_binary_file_atomic(broken,rotated,false);
      bool rejected=false;
      try {(void)hyperdr::verify_encoded_file(broken,encoding,hyperdr::VerificationFrame{source.width,source.height,16,16,source.width-32,source.height-32});}
      catch(const std::exception&){rejected=true;}
      REQUIRE(rejected);std::filesystem::remove(broken);
    }

    if(std::string(format)=="iso-gainmap-jpeg") {
      auto corrupt=bbytes;corrupt.resize(corrupt.size()-2);
      const auto broken=root/"truncated.jpg";hyperdr::write_binary_file_atomic(broken,corrupt,false);
      bool oldRejected=false,newRejected=false;
      try {hyperdr::verify_encoded_output(corrupt,encoding);}catch(const std::exception&){oldRejected=true;}
      try {(void)hyperdr::verify_encoded_file(broken,encoding);}catch(const std::exception&){newRejected=true;}
      REQUIRE(oldRejected&&newRejected);std::filesystem::remove(broken);
      // A wrong photo rectangle exposes known nonzero gain as mat: both the
      // previous whole-rendition criterion and the streamed E5 gate reject it.
      const auto decoded=hyperdr::decode_image(stream);
      REQUIRE(decoded.authored_sdr.has_value());
      const auto sample=(std::size_t(100)*source.width+20)*3;
      REQUIRE(std::abs(decoded.linear_p3.pixels[sample]-decoded.authored_sdr->pixels[sample])>1e-5f);
      bool matRejected=false;
      try {(void)hyperdr::verify_encoded_file(stream,encoding,hyperdr::VerificationFrame{source.width,source.height,32,32,1,1});}
      catch(const std::exception&){matRejected=true;}
      REQUIRE(matRejected);

    }

    float worst=0;
    if(a!=bbytes) {
      const auto x=hyperdr::decode_image(whole),y=hyperdr::decode_image(stream);
      REQUIRE(x.linear_p3.pixels.size()==y.linear_p3.pixels.size());
      for(std::size_t i=0;i<x.linear_p3.pixels.size();++i)worst=std::max(worst,std::abs(x.linear_p3.pixels[i]-y.linear_p3.pixels[i]));
      REQUIRE(worst==0);
    }
    if(std::string(format)=="sdr-tiff")REQUIRE(a==bbytes);
    std::cout<<format<<" bytes_equal="<<(a==bbytes)<<" max_linear_difference="<<worst<<'\n';
    std::filesystem::remove(whole);std::filesystem::remove(stream);
  }
  // Exact zero and tiny positive gain both render once; replay preserves the
  // existing quantization, including unframed dither.
  for(bool framed:{false,true})for(float scale:{0.f,1e-6f}) {
    source.channels=gain.plane.channels=1;source.frame=framed;source.gain_scale=scale;
    request.format="adaptive";request.gain=&gain;
    request.presentation_frame=framed;request.has_frame_photo=framed;
    for(unsigned c=0;c<3;++c)gain.base_offset[c]=gain.alternate_offset[c]=framed?1.f/64:0.f;
    std::vector<float> b(std::size_t(source.width)*source.height*3),g(std::size_t(source.width)*source.height);
    Source::read(&source,0,source.height,b.data(),g.data());
    base.data=b.data();base.size=b.size()*sizeof(float);gain.plane.data=g.data();gain.plane.size=g.size()*sizeof(float);
    request.output_path=whole_path.c_str();char* report=nullptr;error=nullptr;
    auto code=hyperdr_package(engine,&request,&report,&error);status(code,report,error);
    request.output_path=stream_path.c_str();report=nullptr;error=nullptr;source.reads=0;
    code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);status(code,report,error);
    REQUIRE(source.reads==((source.height+12)/13));
    const auto a=hyperdr::decode_image(whole),bimage=hyperdr::decode_image(stream);
    REQUIRE(a.linear_p3.pixels==bimage.linear_p3.pixels);
    std::filesystem::remove(whole);std::filesystem::remove(stream);
  }
  source.gain_scale=1.f;
  // E5 is independent of verify, and a failed staged export preserves a destination.
  hyperdr::write_text_file_atomic(stream,"keep",false);
  request.format="iso-gainmap-jpeg";request.gain=&gain;request.presentation_frame=1;request.has_frame_photo=1;
  request.parameters_json="{\"verify\":false,\"overwrite\":true}";
  source.frame=false;char* failed_report=nullptr;error=nullptr;
  REQUIRE(hyperdr_package_rows(engine,&request,13,Source::read,&source,&failed_report,&error)!=0);
  hyperdr_error_free(error);hyperdr_string_free(failed_report);
  REQUIRE(hyperdr::read_binary_file(stream)==std::vector<std::uint8_t>({'k','e','e','p'}));
  std::filesystem::remove(stream);
  request.format="sdr-jpeg";request.gain=nullptr;request.presentation_frame=0;request.has_frame_photo=0;
  source.fail=true;char* report=nullptr;error=nullptr;
  REQUIRE(hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error)!=0);
  REQUIRE(error&&std::strcmp(error->code,"callback_failed")==0&&!std::filesystem::exists(stream));hyperdr_error_free(error);
  source.fail=false;source.cancel=true;source.token=hyperdr_cancel_create();request.cancel=source.token;
  error=nullptr;
  REQUIRE(hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error)!=0);
  REQUIRE(error&&std::strcmp(error->code,"cancelled")==0&&!std::filesystem::exists(stream));hyperdr_error_free(error);
  hyperdr_cancel_destroy(source.token);hyperdr_engine_destroy(engine);
  for(const auto& entry:std::filesystem::directory_iterator(root))throw std::runtime_error("staging file leaked: "+entry.path().string());
  std::filesystem::remove_all(root);
  return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}

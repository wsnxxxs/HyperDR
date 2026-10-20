#include "hyperdr/hyperdr.h"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>
#include <unistd.h>
#include <mach/mach.h>

#define REQUIRE(x) do { if(!(x))throw std::runtime_error(#x); } while(0)
struct Source {
  unsigned width=65,height=533,channels=1;
  bool frame=false,fail=false,cancel=false;
  hyperdr_cancel* token=nullptr;
  unsigned largest=0;
  static int read(void* context,unsigned y,unsigned count,float* base,float* gain) {
    auto& s=*static_cast<Source*>(context);s.largest=std::max(s.largest,count);
    if(s.fail)return 1;
    if(s.cancel)hyperdr_cancel_request(s.token);
    for(unsigned row=0;row<count;++row)for(unsigned x=0;x<s.width;++x) {
      const auto i=std::size_t(row)*s.width+x;
      const auto u=float(x)/float(s.width-1),v=float(y+row)/float(s.height-1);
      base[i*3]=.1f+.7f*u;base[i*3+1]=.1f+.6f*v;base[i*3+2]=.15f;
      if(gain)for(unsigned c=0;c<s.channels;++c)
        gain[i*s.channels+c]=s.frame&&(x<16||x>=s.width-16||y+row<16||y+row>=s.height-16)?0.f:
            (s.channels==3?-.3f:0.f)+1.8f*u*v*(1-.1f*float(c));
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
  if(probe) { source.width=2048;source.height=argc>2?unsigned(std::stoul(argv[2])):2048; }
  hyperdr_package_plane base{};base.width=source.width;base.height=source.height;base.channels=3;base.format=HYPERDR_PLANE_F32;
  hyperdr_package_gain gain{};gain.plane=base;gain.plane.channels=1;gain.alternate_headroom=2;gain.working_gamut="display-p3";
  hyperdr_package_request request{};request.sdr=&base;request.gain=&gain;
  request.parameters_json=probe?(std::string(argv[1])=="verify"?"{\"verify\":true}":"{\"verify\":false}"):"{\"quality\":93}";
  const auto whole=root/"whole",stream=root/"stream";
  const auto whole_path=whole.string(),stream_path=probe&&argc>5?std::string(argv[5]):stream.string();
  if(probe) {
    const unsigned rows=argc>3?unsigned(std::stoul(argv[3])):64;
    request.format=argc>4?argv[4]:"sdr-tiff";
    request.gain=std::string(request.format).starts_with("sdr-")?nullptr:&gain;
    // Include native E5 readback in gain-map probes.
    source.frame=request.gain!=nullptr;
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
  REQUIRE(!hyperdr_package_rows_supported("avif-pq"));
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
    code=hyperdr_package_rows(engine,&request,13,Source::read,&source,&report,&error);status(code,report,error);
    REQUIRE(source.largest<=13);
    const auto a=hyperdr::read_binary_file(whole),bbytes=hyperdr::read_binary_file(stream);
    const auto encoding=*hyperdr::hdr_encoding_from_name(format);
    const auto verified=hyperdr::verify_encoded_file(stream,encoding);
    REQUIRE(verified.boundedMemory&&verified.pixels==std::uint64_t(source.width)*source.height);
    // Original byte verifier and the new native-row/tile verifier agree on
    // valid files; a truncated codestream must fail both.
    hyperdr::verify_encoded_output(bbytes,encoding);
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

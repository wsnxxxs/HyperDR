#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/app/export_memory.hpp"
#include "export_memory_measurements.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
using namespace hyperdr;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void measured_peaks() {
  for(const auto& r : export_measurements) {
    const auto peak=estimate_export_memory(r.pw,r.ph,r.cw,r.ch,r.encoding,r.depth,true).peak();
    if(peak<r.footprint || peak>r.footprint+r.footprint/2)
      throw std::runtime_error(std::string("measured footprint estimate outside [1,1.5]: ")+r.name);
  }
}
void estimates() {
  constexpr std::uint64_t MiB=1024*1024;
  require(export_memory_budget(0,8*1024*MiB)==7680*MiB,"host reserve");
  require(export_memory_budget(1024*MiB,8*1024*MiB)==1024*MiB,"configured limit");
  require(export_memory_budget(1024*MiB,256*MiB)==0,"host smaller than reserve");
  require(export_memory_budget(1234,0)==1234,"unknown physical memory");
  for(auto mode : {OutputEncoding::IsoGainMapJpeg,OutputEncoding::Adaptive,OutputEncoding::Pq,
                  OutputEncoding::Hlg,OutputEncoding::AvifPq,OutputEncoding::AvifHlg,
                  OutputEncoding::SdrJpeg,OutputEncoding::SdrTiff}) {
    for(int depth : {8,10}) {
      const auto plain=estimate_export_memory(2768,1848,2768,1848,mode,depth,true);
      const auto framed=estimate_export_memory(2768,1848,2972,5284,mode,depth,true);
      require(framed.peak()>=plain.peak(),"larger canvas lowered admission");
      require(plain.decode==framed.decode && plain.render==framed.render,"canvas changed photo stages");
      require(framed.peak()>=framed.encode && framed.peak()>=framed.verify,"encode/verify not included");
      const auto huge=estimate_export_memory(UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,mode,depth,true);
      require(huge.peak()==std::numeric_limits<std::uint64_t>::max(),"overflow admitted giant output");
    }
  }
  const auto one=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Adaptive,10,false,0,0,1);
  const auto four=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Adaptive,10,false,0,0,4);
  require(four.encode>one.encode,"VT batch workers missing from estimate");
  const auto authored=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Adaptive,10,false,0,0,1,true);
  require(authored.render>one.render,"retained authored/model gain planes missing");
  const auto pq8=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Pq,8,false);
  const auto pq10=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Pq,10,false);
  require(pq8.encode==pq10.encode,"PQ encoder always uses Main10 YUV");
  ConvertOptions resources;
  auto frame=std::make_shared<FrameSnapshot>();
  frame->specification_bytes.resize(31);frame->overlay_bytes.resize(19);
  frame->overlay.rgba.resize(64);resources.frame_snapshot=frame;
  auto lut=std::make_shared<ColorLutSnapshot>();
  lut->bytes.resize(23);lut->lut.values.resize(8);resources.color_lut.snapshot=lut;
  auto external=std::make_shared<ExternalGainSnapshot>();
  external->gain_bytes.resize(29);external->report_bytes.resize(17);resources.external_gain_snapshot=external;
  const auto retained=export_resource_bytes(resources);
  const auto expected=frame->specification_bytes.capacity()+frame->overlay_bytes.capacity()+
      frame->overlay.rgba.capacity()*sizeof(float)+lut->bytes.capacity()+
      lut->lut.values.capacity()*sizeof(std::array<float,3>)+external->gain_bytes.capacity()+external->report_bytes.capacity();
  require(retained==expected,"frame overlay/LUT/external snapshots missing from admission");
  const auto loaded=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Adaptive,10,false,0,0,1,false,retained);
  require(loaded.peak()==one.peak()+retained && loaded.decode==one.decode+retained &&
          loaded.verify==one.verify+retained,"retained resources must survive every stage");
  const auto overflow=estimate_export_memory(1024,1024,2048,2048,OutputEncoding::Adaptive,10,false,0,0,1,false,UINT64_MAX);
  require(overflow.peak()==UINT64_MAX,"resource estimate overflow admitted export");
}
#if HYPERDR_WITH_CODECS
void admission() {
  constexpr auto limit=50ULL*1024*1024;
  const auto root=hyperdr::test::temporary_directory()/"export-memory";
  const auto inputs=root/"inputs";
  std::filesystem::create_directories(inputs);
  for(auto size : {64U,600U}) {
    FloatImage photo(size,size==600?400:64,3);
    std::fill(photo.pixels.begin(),photo.pixels.end(),.3F);
    write_binary_file_atomic(inputs/(std::to_string(size)+".tif"),encode_sdr_tiff(photo,{}),true);
  }
  Engine engine({.memory_budget_bytes=limit});
  ConvertOptions options;
  options.input=inputs;options.output_directory=root/"framed";
  options.encoding=OutputEncoding::IsoGainMapJpeg;
  options.frame=parse_frame_spec(json::parse(R"({"margins":0.055,"caption":0.16,"aspect":{"width":9,"height":16}})"));
  const auto report=json::parse(engine.convert(options));
  unsigned passed=0,failed=0;
  for(const auto& f : report.find("files")->array()) {
    if(f.find("success")->boolean()) { ++passed; continue; }
    ++failed;
    require(f.find("error_code")->string()=="export_memory_budget","wrong admission reason code");
    const auto& detail=f.find("detail")->string();
    require(detail.find(std::to_string(limit))!=std::string::npos && detail.find("estimated")!=std::string::npos,
            "admission did not report estimate and budget");
    require(!std::filesystem::exists(path_from_utf8(f.find("output")->string())),"rejected output exists");
  }
  require(passed==1 && failed==1,"rejection must not abort other batch files");
  options.frame.reset();options.output_directory=root/"plain";
  const auto plain=json::parse(engine.convert(options));
  for(const auto& f : plain.find("files")->array()) require(f.find("success")->boolean(),"in-budget unframed export changed");
}
#endif
}
int main() try {
  estimates();
  measured_peaks();
#if HYPERDR_WITH_CODECS
  admission();
#endif
  std::cout<<"export_memory_test passed\n";
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
catch(...) {std::cerr<<"unknown test failure\n";return 1;}

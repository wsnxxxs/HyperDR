#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/app/export_memory.hpp"
#include "export_memory_measurements.hpp"
#include "export_memory_external_measurements.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <fstream>
#include <iostream>
#include <vector>
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
// Measured exports with an external gain grid: never below the real footprint,
// never beyond 1.5 times it (the same band as the RAW matrix above).
void external_measured_peaks() {
  for(const auto& r : external_gain_measurements) {
    const auto peak=estimate_export_memory(r.pw,r.ph,r.cw,r.ch,r.encoding,r.depth,false,0,0,0,true,
        r.grid_pixels*4+r.report_bytes,r.grid_pixels).peak();
    if(peak<r.footprint || peak>r.footprint+r.footprint/2)
      throw std::runtime_error(std::string("external gain estimate outside [1,1.5]: ")+r.name);
  }
}
void external_grid_estimates() {
  constexpr std::uint64_t grid=4096ULL*4096,plane_bytes=grid*4;
  for(auto mode : {OutputEncoding::IsoGainMapJpeg,OutputEncoding::Adaptive,OutputEncoding::Pq,
                  OutputEncoding::AvifPq,OutputEncoding::SdrJpeg}) {
    for(bool framed : {false,true}) {
      const auto cw=framed ? 144U : 128U,ch=framed ? 256U : 128U;
      const auto without=estimate_export_memory(128,128,cw,ch,mode,8,false,0,0,0,true,plane_bytes);
      const auto with=estimate_export_memory(128,128,cw,ch,mode,8,false,0,0,0,true,plane_bytes,grid);
      // The snapshot (retained bytes) plus the parsed grid, canonical grid, stops and
      // statistics copy all exist at once while the gain is applied.
      require(with.render>=plane_bytes*5,"parse/apply working grids missing from render");
      require(with.peak()>=with.render && with.peak()>without.peak()+plane_bytes*3,"grid ignored");
      // Later stages still hold the snapshot; none may fall back to the photo-sized estimate.
      require(with.encode>without.encode && with.verify>without.verify,"grid residue missing after render");
      // Without a grid the estimate is exactly the previous one.
      const auto same=estimate_export_memory(128,128,cw,ch,mode,8,false,0,0,0,true,plane_bytes,0);
      require(same.peak()==without.peak() && same.render==without.render && same.composite==without.composite,
              "zero grid changed the estimate");
    }
  }
  // Grid size is independent of the photo: a 16 MP grid over a 16 K-pixel photo is not 80 B/px of photo.
  const auto small=estimate_export_memory(128,128,128,128,OutputEncoding::IsoGainMapJpeg,8,false,0,0,0,true,plane_bytes,grid);
  require(small.peak()>=20*grid,"a 16 MP grid over a 16 K-pixel photo must cost about 20 B per grid pixel");
  const auto overflow=estimate_export_memory(128,128,128,128,OutputEncoding::IsoGainMapJpeg,8,false,0,0,0,true,0,UINT64_MAX);
  require(overflow.peak()==UINT64_MAX,"grid overflow admitted export");
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
// A synthetic grid and its sidecar. Written in small blocks so the test process
// itself never holds the grid.
void write_gain_grid(const std::filesystem::path& directory,unsigned width,unsigned height,bool v2,
                     std::uint64_t declared_bytes=0) {
  std::filesystem::create_directories(directory);
  {
    std::ofstream out(directory/"gain.f32",std::ios::binary);
    std::vector<float> block(16384);
    const auto count=std::uint64_t(width)*height;
    for(std::uint64_t at=0;at<count;) {
      const auto n=std::min<std::uint64_t>(block.size(),count-at);
      for(std::uint64_t i=0;i<n;++i) {
        const float f=float((at+i)%1000)/999.F;
        block[i]=v2 ? f*1.5F-.5F : f;
      }
      out.write(reinterpret_cast<const char*>(block.data()),std::streamsize(n*sizeof(float)));
      at+=n;
    }
  }
  std::ofstream report(directory/"gain.json");
  report<<"{\"gain_grid_size\":["<<width<<","<<height<<"],";
  if(v2) report<<"\"label_contract_id\":\"hyperdr.apple-gain-label/v2\",";
  else report<<"\"metadata_gain_max_stops\":2.0,";
  report<<"\"gain_file\":{\"format\":\"raw_float32_with_required_json_sidecar\",\"endianness\":\"little\",\"scale\":\""
        <<(v2 ? "signed_log2_gain" : "normalized_log2_gain_0_to_1")<<"\",\"width\":"<<width<<",\"height\":"<<height
        <<",\"byte_length\":"<<(declared_bytes ? declared_bytes : std::uint64_t(width)*height*4)<<"}";
  if(v2) report<<R"(,"gain_metadata":{"minimum_version":0,"writer_version":0,"flags":64,"use_base_color_space":true,)"
      R"("backward_direction":false,"common_denominator":false,)"
      R"("base_headroom":{"numerator":0,"denominator":1000000},"alternate_headroom":{"numerator":2000000,"denominator":1000000},)"
      R"("gain_min":{"numerator":-500000,"denominator":1000000},"gain_max":{"numerator":2000000,"denominator":1000000},)"
      R"("gamma":{"numerator":1000000,"denominator":1000000},"base_offset":{"numerator":0,"denominator":1000000},)"
      R"("alternate_offset":{"numerator":0,"denominator":1000000}})";
  report<<"}\n";
}
// The report must outlive the returned reference.
const json::Value& only_file(const json::Value& report) {
  const auto& files=report.find("files")->array();
  require(files.size()==1,"expected one file in the report");
  return files.front();
}
// R6-E6-1: an external grid is sized by its sidecar, not by the photo, and the
// admission has to know that before the first grid is allocated.
void external_admission() {
  constexpr auto MiB=1024ULL*1024;
  const auto root=hyperdr::test::temporary_directory()/"export-memory-external";
  std::filesystem::remove_all(root);
  const auto input=root/"photo.tif";
  std::filesystem::create_directories(root);
  {
    FloatImage photo(128,128,3);
    std::fill(photo.pixels.begin(),photo.pixels.end(),.3F);
    write_binary_file_atomic(input,encode_sdr_tiff(photo,{}),true);
  }
  const auto story=json::parse(R"({"margins":0.055,"caption":0.16,"aspect":{"width":9,"height":16}})");
  struct Case {const char* name;bool v2;bool framed;};
  // 4096 x 4096 = 64 MiB of floats: about 334 MiB measured at 128 x 128 pixels,
  // three times the 100 MiB below, with only 97 MiB counted before this fix.
  for(const Case c : {Case{"v2",true,true},Case{"v2-unframed",true,false},Case{"v1",false,true},Case{"v1-unframed",false,false}}) {
    const auto grid=root/(std::string("fine-")+c.name);
    write_gain_grid(grid,4096,4096,c.v2);
    Engine engine({.memory_budget_bytes=100*MiB});
    ConvertOptions options;
    options.input=input;options.output_directory=root/(std::string("out-")+c.name);
    options.encoding=OutputEncoding::IsoGainMapJpeg;
    options.external_gain_path=grid/"gain.f32";options.external_gain_report=grid/"gain.json";
    options.allow_legacy_external_gain=!c.v2;
    if(c.framed) options.frame=parse_frame_spec(story);
    const auto report=json::parse(engine.convert(options));
    const auto& file=only_file(report);
    require(!file.find("success")->boolean(),"oversized external grid was admitted");
    require(file.find("error_code")->string()=="export_memory_budget",c.name);
    require(!std::filesystem::exists(path_from_utf8(file.find("output")->string())),"rejected output exists");
  }
  // Within budget: the same kind of export completes (a 2048 x 2048 grid is about 100 MiB).
  const auto fine=root/"fine-ok";
  write_gain_grid(fine,2048,2048,true);
  for(auto mode : {OutputEncoding::IsoGainMapJpeg,OutputEncoding::SdrJpeg}) {
    Engine engine({.memory_budget_bytes=256*MiB});
    ConvertOptions options;
    options.input=input;options.output_directory=root/"out-ok";options.overwrite=true;
    options.encoding=mode;options.frame=parse_frame_spec(story);
    options.external_gain_path=fine/"gain.f32";options.external_gain_report=fine/"gain.json";
    const auto report=json::parse(engine.convert(options));
    const auto& file=only_file(report);
    require(file.find("success")->boolean(),"in-budget external grid export failed");
    require(std::filesystem::exists(path_from_utf8(file.find("output")->string())),"in-budget output missing");
    Engine tight({.memory_budget_bytes=64*MiB});
    const auto tight_report=json::parse(tight.convert(options));
    const auto& refused=only_file(tight_report);
    require(!refused.find("success")->boolean() && refused.find("error_code")->string()=="export_memory_budget",
            "2048 x 2048 grid fits 64 MiB");
  }
  // A pair the parser rejects counts as no grid: the file keeps the parser's own error.
  {
    write_gain_grid(root/"legacy",64,64,false);
    write_gain_grid(root/"short",64,64,true,64*64*4+4);
    Engine engine({.memory_budget_bytes=100*MiB});
    for(const char* name : {"legacy","short"}) {
      ConvertOptions options;
      options.input=input;options.output_directory=root/(std::string("out-")+name);
      options.encoding=OutputEncoding::IsoGainMapJpeg;
      options.external_gain_path=root/name/"gain.f32";options.external_gain_report=root/name/"gain.json";
      const auto report=json::parse(engine.convert(options));
    const auto& file=only_file(report);
      require(!file.find("success")->boolean() && !file.find("error_code"),"invalid sidecar reported as budget");
      const auto& message=file.find("message")->string();
      require(message.find(std::string(name)=="legacy" ? "disabled" : "byte_length")!=std::string::npos ||
              message.find(std::string(name)=="legacy" ? "disabled" : "disagree")!=std::string::npos,message.c_str());
    }
  }
  std::filesystem::remove_all(root);
}
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
  external_grid_estimates();
  external_measured_peaks();
#if HYPERDR_WITH_CODECS
  admission();
  external_admission();
#endif
  std::cout<<"export_memory_test passed\n";
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
catch(...) {std::cerr<<"unknown test failure\n";return 1;}

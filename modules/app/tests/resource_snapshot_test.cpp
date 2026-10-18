#include "hyperdr/app/settings.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include <iostream>
#include <map>
#include <sys/stat.h>
#include <unistd.h>
#include <pthread.h>

namespace {
using namespace hyperdr;
void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
#if HYPERDR_WITH_CODECS
using Bytes = std::vector<std::uint8_t>;
void u16(Bytes& b, unsigned v) { b.push_back(v); b.push_back(v >> 8); }
void u32(Bytes& b, unsigned v) { u16(b,v); u16(b,v >> 16); }
Bytes short_value(unsigned v) { Bytes b; u16(b,v); return b; }
Bytes long_value(unsigned v) { Bytes b; u32(b,v); return b; }
// An uncompressed 96x80 Bayer DNG with an identity camera matrix.
void dng(const std::filesystem::path& path) {
  struct Field { unsigned tag, type, count; Bytes bytes; };
  Bytes matrix, neutral, pixels;
  for (unsigned i=0; i<9; ++i) { u32(matrix,i%4==0); u32(matrix,1); }
  for (unsigned i=0; i<3; ++i) { u32(neutral,1); u32(neutral,1); }
  for (unsigned y=0; y<80; ++y) for (unsigned x=0; x<96; ++x) u16(pixels,1000+300*x+100*y);
  std::vector<Field> fields{
    {256,4,1,long_value(96)},{257,4,1,long_value(80)},{258,3,1,short_value(16)},
    {259,3,1,short_value(1)},{262,3,1,short_value(32803)},{273,4,1,long_value(0)},
    {277,3,1,short_value(1)},{278,4,1,long_value(80)},{279,4,1,long_value(pixels.size())},
    {284,3,1,short_value(1)},{33421,3,2,Bytes{2,0,2,0}},{33422,1,4,Bytes{0,1,1,2}},
    {50706,1,4,Bytes{1,4,0,0}},{50707,1,4,Bytes{1,1,0,0}},
    {50717,4,1,long_value(65535)},{50721,10,9,matrix},{50728,5,3,neutral},
    {50778,3,1,short_value(21)}};
  Bytes header{'I','I',42,0,8,0,0,0}, extra;
  u16(header,fields.size());
  const auto base=14+12*fields.size();
  for (const auto& field : fields) {
    u16(header,field.tag);u16(header,field.type);u32(header,field.count);
    if (field.bytes.size()>4) {
      u32(header,base+extra.size());extra.insert(extra.end(),field.bytes.begin(),field.bytes.end());
      if (extra.size()%2) extra.push_back(0);
    } else {
      header.insert(header.end(),field.bytes.begin(),field.bytes.end());
      header.resize(header.size()+4-field.bytes.size(),0);
    }
  }
  u32(header,0);
  // The sixth field is StripOffsets.
  const auto offset=base+extra.size();
  for (unsigned i=0;i<4;++i) header[10+5*12+8+i]=offset>>(i*8);
  header.insert(header.end(),extra.begin(),extra.end());header.insert(header.end(),pixels.begin(),pixels.end());
  write_binary_file_atomic(path,header,true);
}
void calibration(const std::filesystem::path& root) {
  const auto input=root/"sensor.dng";
  dng(input);
  for (unsigned kind=0;kind<4;++kind) {
    ConvertOptions options;
    options.input=input;
    const auto resource=root/("calibration-"+std::to_string(kind));
    if (kind==0) { options.raw.bad_pixel_map=resource; write_text_file_atomic(resource,"24 24 0\n",true); }
    if (kind==1) {
      options.raw.dark_frame=resource;
      const std::string header="P5\n96 80\n65535\n";
      Bytes bytes(header.begin(),header.end());bytes.resize(bytes.size()+96*80*2,0);
      write_binary_file_atomic(resource,bytes,true);
    }
    if (kind==2) { options.raw.linearization_lut=resource; write_text_file_atomic(resource,"2\n0 65535\n",true); }
    if (kind==3) { options.raw.lens_shading_map=resource; write_text_file_atomic(resource,"1 1 1\n1\n",true); }
    const auto original=read_binary_file(resource);
    const auto signature=settings_signature(options);
    const auto model=model_preprocessing_fingerprint(options);
    const auto cache=decode_cache_variant(options,options.raw);
    prepare_conversion_resources(options);
    require(settings_signature(options)==signature,"snapshot changed unchanged-input signature");
    const auto expected=decode_image(input,options.raw);
    std::filesystem::remove(resource);
    require(settings_signature(options)==signature,"fingerprint reopened captured calibration");
    require(model_preprocessing_fingerprint(options)==model,"model fingerprint reopened calibration");
    require(decode_cache_variant(options,options.raw)==cache,"decode cache key reopened calibration");
    const auto actual=decode_image(input,options.raw);
    require(actual.linear_p3.pixels==expected.linear_p3.pixels,"RAW decode reopened captured calibration");
    write_binary_file_atomic(resource,original,true);
    ConvertOptions next;
    next.raw=options.raw;next.raw.snapshots.reset();
    write_text_file_atomic(resource,"broken\n",true);
    prepare_conversion_resources(next);
    require(settings_signature(next)!=settings_signature(options),"next entry retained stale calibration");
  }
}
// Minimal identity camera profile, as tests/capi/contract_test.py writes it.
void dcp(const std::filesystem::path& path) {
  struct Field { unsigned tag, type, count; Bytes bytes; };
  Bytes matrix;
  for (unsigned i=0; i<9; ++i) { u32(matrix,i%4==0); u32(matrix,1); }
  const std::string name="Synthetic";
  std::vector<Field> fields{{50708,2,1,Bytes{0}},{50721,10,9,matrix},{50778,3,1,short_value(21)},
                            {50936,2,10,Bytes(name.begin(),name.end()+1)}};
  Bytes entries,payload;
  for (const auto& field : fields) {
    u16(entries,field.tag);u16(entries,field.type);u32(entries,field.count);
    if (field.bytes.size()<=4) {
      entries.insert(entries.end(),field.bytes.begin(),field.bytes.end());
      entries.resize(entries.size()+4-field.bytes.size(),0);
    } else {
      u32(entries,14+12*fields.size()+payload.size());
      payload.insert(payload.end(),field.bytes.begin(),field.bytes.end());
    }
  }
  Bytes bytes{'I','I'};u16(bytes,0x4352);u32(bytes,8);u16(bytes,fields.size());
  bytes.insert(bytes.end(),entries.begin(),entries.end());u32(bytes,0);
  bytes.insert(bytes.end(),payload.begin(),payload.end());
  write_binary_file_atomic(path,bytes,true);
}
using CacheState = std::map<std::filesystem::path,std::pair<long long,Bytes>>;
CacheState cache_state(const std::filesystem::path& directory) {
  CacheState state;
  for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
    if (!entry.is_regular_file()) continue;
    struct stat info{};
    require(stat(entry.path().c_str(),&info)==0,"stat decode cache");
    state[entry.path()]={info.st_mtimespec.tv_sec*1000000000LL+info.st_mtimespec.tv_nsec,
                         read_binary_file(entry.path())};
  }
  return state;
}
// A preview's half-size disk cache must check the captured DCP, not reopen its
// path: deleting or replacing the file after capture keeps the cache entry.
void preview_disk_cache(const std::filesystem::path& root) {
  const auto input=root/"preview.dng",profile=root/"camera.dcp",cache=root/"preview-cache";
  dng(input);dcp(profile);
  const auto original=read_binary_file(profile);
  for (const bool replace : {false,true}) {
    std::filesystem::remove_all(cache);
    ConvertOptions options;
    options.input=input;options.raw.profile=profile;options.raw.half_size=true;
    options.preview_max_edge=2048;options.decode_cache_directory=cache;
    PreviewSession warm(input,{},{});
    const auto expected=warm.render_pixels(options);
    const auto before=cache_state(cache);
    require(!before.empty(),"preview did not write its disk cache");
    prepare_conversion_resources(options);
    if (replace) { auto other=original;other.push_back(0);write_binary_file_atomic(profile,other,true); }
    else std::filesystem::remove(profile);
    PreviewSession cold(input,{},{});
    const auto actual=cold.render_pixels(options);
    require(actual.base.pixels==expected.base.pixels,"preview changed after its DCP was captured");
    require(cache_state(cache)==before,"preview disk cache reopened the captured DCP path");
    write_binary_file_atomic(profile,original,true);
  }
}
// Invalid external gain content fails only that file; the batch still reports.
void external_gain_content(const std::filesystem::path& root) {
  const auto input=root/"external.dng",gain=root/"gain.f32",report=root/"gain.json";
  dng(input);
  write_binary_file_atomic(gain,Bytes(20,0),true); // the report promises 16
  std::string metadata;
  for (const char* key : {"base_headroom","alternate_headroom","gain_min","gain_max","gamma",
                          "base_offset","alternate_offset"}) {
    const bool three=std::string_view(key)=="alternate_headroom" || std::string_view(key)=="gain_max";
    metadata+=std::string(metadata.empty()?"":",")+"\""+key+"\":{\"numerator\":"+(three?"3":
        std::string_view(key)=="gamma"?"1":"0")+",\"denominator\":1}";
  }
  write_text_file_atomic(report,"{\"gain_grid_size\":[2,2],\"label_contract_id\":\"hyperdr.apple-gain-label/v2\","
      "\"gain_metadata\":{"+metadata+"},\"gain_file\":{\"format\":\"raw_float32_with_required_json_sidecar\","
      "\"endianness\":\"little\",\"scale\":\"signed_log2_gain\",\"width\":2,\"height\":2,"
      "\"byte_length\":16,\"sha256\":\""+sha256_hex(Bytes(20,0))+"\"}}",true);
  ConvertOptions options;
  options.input=input;options.output_directory=root/"external-out";options.encoding=OutputEncoding::SdrJpeg;
  options.external_gain_path=gain;options.external_gain_report=report;
  std::string text;
  const auto code=run_conversion(options,nullptr,&text);
  require(code==1,"invalid external gain content must fail only its file");
  const auto parsed=json::parse(text);
  const auto* files=parsed.find("files");
  require(files && files->array().size()==1,"external gain report lacks its file");
  const auto& file=files->array()[0];
  require(!file.find("success")->boolean() &&
          file.find("message")->string().find("external gain byte length does not match its report")!=std::string::npos,
          "per-file external gain failure missing from report");
}
#endif
void snapshot_identity(const std::filesystem::path& root) {
  ConvertOptions options;
  const auto lut=root/"look.cube";
  write_text_file_atomic(lut,"LUT_1D_SIZE 2\n0 0 0\n1 1 1\n",true);
  options.color_lut.path=lut;
  options.output_directory=root;
  const auto signature=settings_signature(options);
  prepare_conversion_resources(options);
  require(settings_signature(options)==signature,"snapshot changed unchanged LUT signature");
  require(options.color_lut.snapshot->sha256==sha256_hex(options.color_lut.snapshot->bytes),"LUT digest mismatch");
  std::filesystem::remove(lut);
  validate_convert_options(options);
  require(settings_signature(options)==signature,"LUT fingerprint reopened path");
}
}
int run() {
  const auto root=std::filesystem::temp_directory_path()/("hyperdr-resource-snapshot-"+std::to_string(getpid()));
  try {
    std::filesystem::create_directories(root);
    snapshot_identity(root);
#if HYPERDR_WITH_CODECS
    calibration(root);
    preview_disk_cache(root);
    external_gain_content(root);
#endif
    std::filesystem::remove_all(root);
    std::cout<<"resource snapshots preserve fingerprints and decode without their paths\n";
    return 0;
  } catch(const std::exception& error) {
    std::filesystem::remove_all(root);std::cerr<<error.what()<<'\n';return 1;
  }
}

int main() {
  pthread_attr_t attributes;
  if (pthread_attr_init(&attributes) != 0) return 2;
  if (pthread_attr_setstacksize(&attributes, 512U*1024U) != 0) {
    pthread_attr_destroy(&attributes);return 2;
  }
  int result=2;
  pthread_t thread;
  const int status=pthread_create(&thread,&attributes,[](void* value)->void* {
    *static_cast<int*>(value)=run();return nullptr;
  },&result);
  pthread_attr_destroy(&attributes);
  if (status != 0 || pthread_join(thread,nullptr) != 0) return 2;
  return result;
}

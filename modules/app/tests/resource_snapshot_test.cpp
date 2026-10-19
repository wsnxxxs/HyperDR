#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/foundation/file_io.hpp"
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
void external_gain_content(const std::filesystem::path& root) {
  const auto input=std::filesystem::path(HYPERDR_SOURCE_DIR)/"build/fixtures/sony-ilce-7s.ARW";
  const auto gain=root/"gain.f32",report=root/"gain.json";
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
  const auto root=hyperdr::test::temporary_directory()/("hyperdr-resource-snapshot-"+std::to_string(getpid()));
  try {
    std::filesystem::create_directories(root);
    snapshot_identity(root);
#if HYPERDR_WITH_CODECS
    external_gain_content(root);
#endif
    std::filesystem::remove_all(root);
    std::cout<<"resource snapshots preserve fingerprints and decode without their paths\n";
    return 0;
  } catch(const std::exception& error) {
    std::filesystem::remove_all(root);std::cerr<<error.what()<<'\n';return 1;
  }
}

int main() try {
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
} catch (const std::exception& error) {
  std::cerr << "test failure: " << error.what() << '\n';
  return 1;
} catch (...) {
  std::cerr << "unknown test failure\n";
  return 1;
}

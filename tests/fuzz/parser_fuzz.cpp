#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/container/inspect.hpp"
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>
#ifndef HYPERDR_FUZZ_TARGET
#error Missing parser selection
#endif
extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t* data,std::size_t size){
 if(size>65536)return 0;
 try{
#if HYPERDR_FUZZ_TARGET == 1
  const auto file=hyperdr::read_heif({data,size});
  (void)file.resolve_image();(void)file.resolve_gain_map();(void)file.resolve_alpha();
  (void)file.exif();(void)file.xmp();(void)file.normalized_json();
#elif HYPERDR_FUZZ_TARGET == 2
  (void)hyperdr::inspection_json(hyperdr::inspect_heif({data,data+size}));
#elif HYPERDR_FUZZ_TARGET == 3
  (void)hyperdr::parse_tmap_payload({data,data+size});
#elif HYPERDR_FUZZ_TARGET == 4
  (void)hyperdr::read_exif(data,size);(void)hyperdr::read_apple_legacy_gain_headroom(data,size);
#elif HYPERDR_FUZZ_TARGET == 5
  (void)hyperdr::parse_hevc_configuration({data,size});
#endif
 }catch(const std::exception&){}
 return 0;
}

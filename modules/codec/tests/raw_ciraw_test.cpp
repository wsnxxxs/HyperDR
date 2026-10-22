#include "../src/internal/raw_ciraw.hpp"

#include <mach/mach.h>
#include <malloc/malloc.h>
#if __has_feature(address_sanitizer)
#include <sanitizer/allocator_interface.h>
#endif
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <array>
#include <cstdlib>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

#include "../src/internal/budget.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/hash.hpp"
#include <exception>
using namespace hyperdr;
namespace {
void require(bool v, const char* message) {
  if (!v) throw std::runtime_error(message);
}
const auto fixtures =
    std::filesystem::path(HYPERDR_SOURCE_DIR) / "build/fixtures";
std::size_t live_allocated_bytes() {
#if __has_feature(address_sanitizer)
  // Live allocations, not quarantine, resident pages or the high-water mark.
  return __sanitizer_get_current_allocated_bytes();
#else
  malloc_statistics_t statistics{};
  malloc_zone_statistics(nullptr,&statistics);
  return statistics.size_in_use;
#endif
}
void repeated_cancel_allocations(const std::filesystem::path& source) {
  constexpr unsigned warmup=4,measured=20,window=5;
  std::array<std::size_t,measured> live{};
  for(unsigned i=0;i<warmup+measured;++i){
    CancelToken token;unsigned checks=0;const unsigned checkpoint=(i%2)*16;
    testing::set_raw_copy_hook([&](unsigned row){++checks;if(row==checkpoint)token.request();});
    bool cancelled=false;
    try{CancelScope scope(&token);(void)decode_image(source);}
    catch(const Cancelled&){cancelled=true;}
    catch(...){testing::set_raw_copy_hook({});release_apple_raw_cache(source);throw;}
    testing::set_raw_copy_hook({});release_apple_raw_cache(source);
    require(cancelled && checks==1+i%2,"repeated cancellation missed checkpoint");
    if(i>=warmup)live[i-warmup]=live_allocated_bytes();
  }
  double first=0,last=0;
  for(unsigned i=0;i<window;++i){first+=live[i]/double(window);last+=live[measured-window+i]/double(window);}
  std::cout<<"RAW repeated_cancel warmup="<<warmup<<" samples="<<measured
           <<" live_first_window="<<first<<" live_last_window="<<last<<" growth="<<last-first<<'\n';
  // Original unpopped pools retain about 1.66MB per cancellation (>24MB
  // between these windows). Allow 4MiB for system/decoder cache noise; the
  // check does not depend on ASan quarantine size or heap page reclamation.
  require(last<=first+4*1024*1024,"RAW cancellation retained live allocations across calls");
}
void run() {
  const auto source=fixtures/"sony-ilce-7s.ARW";
  Engine engine;
  const auto renders=testing::raw_filter_render_count();
  const auto probe=json::parse(engine.probe(source));
  require(probe.find("width")->number()==2768 && probe.find("height")->number()==1848,"7S crop");
  require(testing::raw_filter_render_count()==renders,"probe rendered pixels");
  RawDecodeOptions options;options.preview_max_edge=256;
  const auto decoded=decode_image(source,options);
  require(!decoded.linear_p3.pixels.empty() && decoded.domain==InputDomain::kSceneReferred,"RAW decode contract");
  release_apple_raw_cache(source);
  repeated_cancel_allocations(source);
}
}
int main() try { run(); return 0; }
catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}

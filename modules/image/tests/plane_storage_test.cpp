#include "hyperdr/image/image.hpp"
#include <cerrno>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <unistd.h>

namespace {
void require(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
}
int main() try {
  using namespace hyperdr;
  FloatImage small(8,8,3);
  for(std::size_t i=0;i<small.pixels.size();++i)small.pixels[i]=float(i)/256;
  auto copy=small;
  require(copy.pixels==small.pixels,"small plane copy changed samples");
  FloatImage large(1024,1024,3);
  for(std::size_t i=0;i<large.pixels.size();++i)large.pixels[i]=float(i%8192)/4096;
  const auto* address=large.pixels.data();
  auto moved=std::move(large);
  require(moved.pixels.data()==address,"moving a large plane copied its allocation");
  auto duplicate=moved;
  require(duplicate.pixels==moved.pixels && duplicate.pixels.data()!=address,"large copy lost ownership or samples");
#if !__has_feature(address_sanitizer)
  // The former virtual range must really be unmapped, rather than cached by
  // malloc. This pins the lifetime guarantee behind the footprint estimate.
  const auto page=static_cast<std::size_t>(sysconf(_SC_PAGESIZE));
  char resident=0;
  require(mincore(const_cast<float*>(address),page,&resident)==0,"large plane is not mapped");
  moved=FloatImage{};
  mach_vm_address_t region=reinterpret_cast<mach_vm_address_t>(address);
  mach_vm_size_t length=0;
  vm_region_basic_info_data_64_t info{};
  mach_msg_type_number_t count=VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object=MACH_PORT_NULL;
  const auto result=mach_vm_region(mach_task_self(),&region,&length,VM_REGION_BASIC_INFO_64,
      reinterpret_cast<vm_region_info_t>(&info),&count,&object);
  if(object!=MACH_PORT_NULL)mach_port_deallocate(mach_task_self(),object);
  require(result==KERN_INVALID_ADDRESS || (result==KERN_SUCCESS && region>reinterpret_cast<mach_vm_address_t>(address)),
          "releasing a large plane retained its mapped pages");
#endif
  bool overflow=false;
  try {auto* p=PlaneAllocator<float>{}.allocate(std::numeric_limits<std::size_t>::max());
       PlaneAllocator<float>{}.deallocate(p,std::numeric_limits<std::size_t>::max());}
  catch(const std::bad_array_new_length&){overflow=true;}
  require(overflow,"plane byte count overflow did not fail");
  std::cout<<"plane_storage_test passed\n";
} catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
catch(...) {std::cerr<<"unknown test failure\n";return 1;}

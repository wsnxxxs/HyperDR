// Manual container-only memory probe; framing-valid synthetic IDRs, not decodable video.
#include "../../modules/container/tests/heif_writer_fixture.hpp"
#include <mach/mach.h>
#include <iostream>
int main() {
  constexpr unsigned width=9568,height=6376;
  auto sequence=writer_fixture::sequence(8,((width+511)/512)*((height+511)/512));
  for(auto& sample:sequence.samples) {
    sample.resize(256*1024,0x80);
    const auto nal=unsigned(sample.size()-4);
    for(unsigned i=0;i<4;++i)sample[i]=nal>>(24-i*8);
  }
  hyperdr::HeifEncodedImage image{sequence,width,height,{},std::nullopt,{}};
#ifdef HYPERDR_HEIF_VECTOR_OUTPUT
  const auto bytes=hyperdr::write_heif(image);
  hyperdr::write_binary_file_atomic("build/tmp/memory.heic",bytes,true);
  const auto size=bytes.size();
#else
  std::ofstream output("build/tmp/memory.heic",std::ios::binary|std::ios::trunc);
  output.exceptions(std::ios::failbit|std::ios::badbit);
  std::size_t size=0;
  hyperdr::write_heif_to([&](auto part){output.write(reinterpret_cast<const char*>(part.data()),part.size());size+=part.size();},image);
  output.close();
#endif
  task_vm_info_data_t vm{};mach_msg_type_number_t count=sizeof(vm)/sizeof(integer_t);
  task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&vm),&count);
  std::cout<<"pixels="<<std::uint64_t(width)*height<<" samples="<<sequence.samples.size()<<" bytes="<<size<<" peak="<<vm.ledger_phys_footprint_peak<<"\n";
}

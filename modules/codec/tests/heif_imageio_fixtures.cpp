// Real VT pictures for the independent ImageIO grid/auxiliary gate.
#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/icc_profiles.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include <pthread.h>
#include <algorithm>
#include <array>
#include <exception>
#include <iostream>
#include <map>
#include <memory>

namespace {
using namespace hyperdr;
void require(bool ok,const char* message){if(!ok)throw std::runtime_error(message);}
void check_items(const std::vector<std::uint8_t>& bytes,unsigned tiles,bool grid) {
  const auto file=read_heif(bytes);
  const unsigned gain=grid?tiles+2:2,tmap=grid?2*(tiles+1)+1:3;
  require(file.items.size()==tmap,"grid item budget mismatch");
  using Key=std::pair<unsigned,std::string>;
  std::map<Key,std::vector<std::uint32_t>> expected,actual;
  expected[{gain,"auxl"} ]={1};expected[{tmap,"dimg"} ]={1,gain};
  if(grid)for(unsigned i=0;i<tiles;++i){expected[{1,"dimg"} ].push_back(2+i);expected[{gain,"dimg"} ].push_back(gain+1+i);}
  for(const auto& [id,item]:file.items){
    require(id>=1 && id<=tmap,"unexpected item ID");
    const char* wanted=id==tmap?"tmap":grid&&(id==1||id==gain)?"grid":"hvc1";
    require(item.type==wanted,"incorrect item type");
  }
  for(const auto& reference:file.references){
    const Key key{reference.from,reference.type};require(!actual.contains(key),"repeated reference group");
    actual[key]=reference.to;
  }
  require(actual==expected,"incomplete item/reference enumeration");
}
void generate(const std::filesystem::path& directory){
  using namespace codec::hevc;
  const auto icc=codec::display_p3_profile();
  for(const int depth:{8,10})for(const auto size:std::array{std::array{64U,64U},std::array{63U,47U},std::array{1U,1U},std::array{512U,512U},std::array{513U,513U},std::array{768U,768U}}){
    const auto [width,height]=size;const auto grid=tile_grid(width,height);
    EncodeParams p;p.main10=depth==10;p.color={12,13,1};
    auto base=encode(grid.count(),[&](std::size_t index,YuvTile& tile){
      rgb_tile(grid,index,[](auto,auto,auto count,float* values){std::fill_n(values,count*3,.5F);},1,true,tile);
    },p);
    p.main10=false;p.color={2,2,1};
    auto gain=encode(grid.count(),[&](std::size_t index,YuvTile& tile){
      luma_tile(grid,index,[](auto,auto,auto count,float* values){std::fill_n(values,count,.5F);},tile);
    },p);
    HeifEncodedImage b{base,width,height,{},std::nullopt,icc},g{gain,width,height,{2,2,1,true},std::nullopt,{}};
    HeifWriteOptions options;options.gain_metadata=GainMapMetadata{};
    auto bytes=write_heif(b,&g,options);
    require(inspect_heif(bytes).structurally_valid,"inspect rejected cropped grid");
    check_items(bytes,grid.count(),width!=512||height!=512);
    const auto name=std::to_string(width)+"x"+std::to_string(height)+"-"+std::to_string(depth)+".heic";
    write_binary_file_atomic(directory/name,bytes,true);
    std::cout<<name<<" structure/items/references passed on 512KB stack\n";
  }
}
struct Run {std::filesystem::path directory;std::exception_ptr error;};
void* run(void* value){auto& r=*static_cast<Run*>(value);try{generate(r.directory);}catch(...){r.error=std::current_exception();}return nullptr;}
}
int main(int argc,char** argv){try{
  require(argc==2,"usage: heif_imageio_fixtures OUTPUT_DIRECTORY");
  Run state{argv[1],{}};std::filesystem::create_directories(state.directory);
  pthread_attr_t attr;require(pthread_attr_init(&attr)==0,"pthread attributes");
  require(pthread_attr_setstacksize(&attr,512*1024)==0,"512KB stack size");pthread_t thread;
  const int status=pthread_create(&thread,&attr,run,&state);pthread_attr_destroy(&attr);
  require(status==0,"start 512KB thread");require(pthread_join(thread,nullptr)==0,"join fixture thread");
  if(state.error)std::rethrow_exception(state.error);
}catch(const std::exception& e){std::cerr<<"HEIF ImageIO fixture failure: "<<e.what()<<'\n';return 1;}}

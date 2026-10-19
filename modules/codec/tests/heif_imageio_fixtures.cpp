// Real VT pictures for the independent ImageIO grid/auxiliary gate.
#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/icc_profiles.hpp"
#include <libheif/heif.h>
#include <libheif/heif_items.h>
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
void checked(heif_error e){if(e.code!=heif_error_Ok)throw std::runtime_error(e.message);}
void check_items(const std::vector<std::uint8_t>& bytes,unsigned tiles,bool grid) {
  std::unique_ptr<heif_context,decltype(&heif_context_free)> c(heif_context_alloc(),heif_context_free);
  require(bool(c),"allocate grid verification context");
  checked(heif_context_read_from_memory_without_copy(c.get(),bytes.data(),bytes.size(),nullptr));
  const unsigned gain=grid?tiles+2:2,tmap=grid?2*(tiles+1)+1:3;
  require(heif_context_get_number_of_items(c.get())==int(tmap),"grid item budget mismatch");
  std::vector<heif_item_id> ids(tmap);
  require(heif_context_get_list_of_item_IDs(c.get(),ids.data(),ids.size())==int(tmap),"incomplete item enumeration");
  using Key=std::pair<unsigned,std::uint32_t>;
  std::map<Key,std::vector<heif_item_id>> expected,actual;
  auto type=[](const char* s){return heif_fourcc(s[0],s[1],s[2],s[3]);};
  expected[{gain,type("auxl")} ]={1};expected[{tmap,type("dimg")} ]={1,gain};
  if(grid)for(unsigned i=0;i<tiles;++i){expected[{1,type("dimg")} ].push_back(2+i);expected[{gain,type("dimg")} ].push_back(gain+1+i);}
  for(auto id:ids){
    require(id>=1 && id<=tmap,"unexpected item ID");
    const auto wanted=id==tmap?type("tmap"):grid&&(id==1||id==gain)?type("grid"):type("hvc1");
    require(heif_item_get_item_type(c.get(),id)==wanted,"incorrect item type");
    for(int index=0;;++index){std::uint32_t kind=0;heif_item_id* targets=nullptr;
      auto n=heif_context_get_item_references(c.get(),id,index,&kind,&targets);
      if(!n){require(!targets,"empty item reference allocation");break;}
      const Key key{id,kind};require(!actual.contains(key),"repeated reference group");
      actual[key]={targets,targets+n};heif_release_item_references(c.get(),&targets);
    }
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

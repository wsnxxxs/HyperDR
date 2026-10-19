#include "heif_writer_fixture.hpp"
#include "../../codec/src/hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include <array>
#include <iostream>
#include <map>

// The five writer goldens read back through our own reader: every item and
// its type, every ordered reference, the alternative group, and the primary
// image's size, colour, light level and bit depth. ImageIO is the independent
// reader of real files (heif_writer_imageio_test); these goldens' pictures are
// deliberately undecodable, so this test is about the container only.
namespace {
void require(bool okay,const char* message){if(!okay)throw std::runtime_error(message);}
using Reference=std::pair<std::uint32_t,std::string>;
void check(const std::string& name) {
  const auto bytes=writer_fixture::file(name);
  if(name=="single8") {
    auto data=writer_fixture::sequence(8,1);
    hyperdr::codec::hevc::EncodedSequence actual{data.vps,data.sps,data.pps,data.samples};
    hyperdr::HeifEncodedImage image{actual,512,512,{},std::nullopt,{}};
    require(hyperdr::write_heif(image)==bytes,"VT EncodedSequence adapter changes bytes");
  }
  const auto file=hyperdr::read_heif(bytes);
  const bool adaptive=name.starts_with("adaptive"), grid=name=="adaptive8-grid" || name=="grid10-hlg";
  const bool derived=name!="single8";
  const unsigned leaves=grid?4:1;
  const int count=adaptive?int(2*(leaves+1)+3):derived?int(leaves+1):1;
  require(file.items.size()==std::size_t(count),"reader must enumerate every item");
  std::map<Reference,std::vector<std::uint32_t>> expected_refs,refs;
  std::map<std::uint32_t,std::string> expected_types;
  if(derived) {
    expected_types[1]="grid";
    for(unsigned i=2;i<=leaves+1;++i)expected_refs[{1,"dimg"} ].push_back(i);
    for(unsigned i=2;i<=leaves+1;++i)expected_types[i]="hvc1";
  } else expected_types[1]="hvc1";
  if(adaptive) {
    const unsigned gain=leaves+2,tmap=2*(leaves+1)+1;
    expected_types[gain]="grid";
    for(unsigned i=gain+1;i<gain+1+leaves;++i){
      expected_refs[{gain,"dimg"} ].push_back(i);expected_types[i]="hvc1";
    }
    expected_types[tmap]="tmap";expected_types[tmap+1]="Exif";expected_types[tmap+2]="mime";
    expected_refs[{tmap,"dimg"} ]={1,gain};
    expected_refs[{gain,"auxl"} ]={1};
    expected_refs[{tmap+1,"cdsc"} ]={1};expected_refs[{tmap+2,"cdsc"} ]={1};
  }
  for(const auto& [id,item]:file.items)
    require(expected_types.contains(id) && item.type==expected_types.at(id),"item type/ID differs");
  for(const auto& reference:file.references) {
    const Reference key{reference.from,reference.type};
    require(!refs.contains(key),"duplicate item reference");
    refs[key]=reference.to;
  }
  require(refs==expected_refs,"reader must expose all ordered dimg/auxl/cdsc references");
  std::size_t altr=0;
  for(const auto& group:file.groups) if(group.type=="altr") {
    ++altr;
    require(group.id==unsigned(count+1) && group.members==std::vector<std::uint32_t>{unsigned(2*(leaves+1)+1),1},
            "altr group ID/ordered members");
  }
  require(altr==(adaptive?1U:0U),"altr group count");
  const auto plan=file.resolve_image();
  require(plan.width==(grid?700:name=="single8"?512:127) &&
          plan.height==(grid?513:name=="single8"?512:95),"grid dimensions");
  require(plan.color && plan.color->primaries==(adaptive||name=="single8"?12:9) &&
      plan.color->transfer==(adaptive||name=="single8"?13:grid?18:16) &&
      plan.color->matrix==(adaptive||name=="single8"?1:9) && plan.color->full_range,
      "nclx differs");
  require(plan.icc.empty()!=adaptive,"Adaptive P3 ICC presence");
  const bool has_light=plan.light.has_value();
  require(has_light==(!adaptive && name!="single8"),"clli presence");
  if(has_light)require(plan.light->maximum==1000 && plan.light->average==400,"clli values");
  require(plan.config.bit_depth==unsigned(name=="single8"||name=="adaptive8-grid"?8:10),"hvcC bit depth");
  std::cout<<name<<": reader found "<<count<<" items, "<<refs.size()<<" reference sets\n";
}
}
int main(){try{for(const auto& name:writer_fixture::names())check(name);}
catch(const std::exception& error){std::cerr<<"heif_writer_items_test: "<<error.what()<<'\n';return 1;}}

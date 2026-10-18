#include "heif_writer_fixture.hpp"
#include "../../codec/src/hevc/hevc.hpp"
#include <libheif/heif.h>
#include <libheif/heif_items.h>
#include <libheif/heif_color.h>
#include <array>
#include <iostream>
#include <map>
#include <memory>

namespace {
void require(bool okay,const char* message){if(!okay)throw std::runtime_error(message);}
void checked(heif_error error){if(error.code!=heif_error_Ok)throw std::runtime_error(error.message);}
using Reference=std::pair<heif_item_id,std::uint32_t>;
std::uint32_t type(const char* text){return heif_fourcc(text[0],text[1],text[2],text[3]);}
void check(const std::string& name) {
  const auto bytes=writer_fixture::file(name);
  if(name=="single8") {
    auto data=writer_fixture::sequence(8,1);
    hyperdr::codec::hevc::EncodedSequence actual{data.vps,data.sps,data.pps,data.samples};
    hyperdr::HeifEncodedImage image{actual,512,512,{},std::nullopt,{}};
    require(hyperdr::write_heif(image)==bytes,"VT EncodedSequence adapter changes bytes");
  }
  std::unique_ptr<heif_context,decltype(&heif_context_free)> context(heif_context_alloc(),heif_context_free);
  require(bool(context),"allocate libheif context");
  checked(heif_context_read_from_memory_without_copy(context.get(),bytes.data(),bytes.size(),nullptr));
  const bool adaptive=name.starts_with("adaptive"), grid=name=="adaptive8-grid" || name=="grid10-hlg";
  const int count=adaptive?(grid?13:5):(grid?5:1);
  require(heif_context_get_number_of_items(context.get())==count,"libheif must enumerate every item");
  std::vector<heif_item_id> ids(count);
  require(heif_context_get_list_of_item_IDs(context.get(),ids.data(),count)==count,"libheif item IDs");
  std::map<Reference,std::vector<heif_item_id>> expected_refs,refs;
  std::map<heif_item_id,std::uint32_t> expected_types;
  if(grid) {
    expected_types[1]=type("grid");
    expected_refs[{1,type("dimg")} ]={2,3,4,5};
    for(unsigned i=2;i<=5;++i)expected_types[i]=type("hvc1");
  } else expected_types[1]=type("hvc1");
  if(adaptive) {
    const unsigned gain=grid?6:2,tmap=grid?11:3;
    expected_types[gain]=type(grid?"grid":"hvc1");
    if(grid){expected_refs[{gain,type("dimg")} ]={7,8,9,10};for(unsigned i=7;i<=10;++i)expected_types[i]=type("hvc1");}
    expected_types[tmap]=type("tmap");expected_types[tmap+1]=type("Exif");expected_types[tmap+2]=type("mime");
    expected_refs[{tmap,type("dimg")} ]={1,gain};
    expected_refs[{gain,type("auxl")} ]={1};
    expected_refs[{tmap+1,type("cdsc")} ]={1};expected_refs[{tmap+2,type("cdsc")} ]={1};
  }
  for(const auto id:ids) {
    require(expected_types.contains(id) && heif_item_get_item_type(context.get(),id)==expected_types.at(id),
            "libheif item type/ID differs");
    for(int index=0;;++index) {
      std::uint32_t reference_type=0;heif_item_id* targets=nullptr;
      const auto n=heif_context_get_item_references(context.get(),id,index,&reference_type,&targets);
      if(!n){require(!targets,"empty item references");break;}
      const auto key=Reference{id,reference_type};
      require(!refs.contains(key),"duplicate libheif item reference");
      refs[key]=std::vector<heif_item_id>(targets,targets+n);
      heif_release_item_references(context.get(),&targets);
    }
  }
  require(refs==expected_refs,"libheif must expose all ordered dimg/auxl/cdsc references");
  int group_count=0;
  auto* groups=heif_context_get_entity_groups(context.get(),type("altr"),0,&group_count);
  require(group_count==(adaptive?1:0),"libheif altr group count");
  if(adaptive) {
    require(groups && groups[0].entity_group_id==unsigned(count+1) && groups[0].num_entities==2 &&
        groups[0].entities[0]==unsigned(grid?11:3) && groups[0].entities[1]==1,"libheif altr ID/ordered members");
  }
  heif_entity_groups_release(groups,group_count);
  heif_image_handle* raw=nullptr;checked(heif_context_get_primary_image_handle(context.get(),&raw));
  std::unique_ptr<heif_image_handle,decltype(&heif_image_handle_release)> handle(raw,heif_image_handle_release);
  require(heif_image_handle_get_width(raw)==(grid?700:name=="single8"?512:127) &&
          heif_image_handle_get_height(raw)==(grid?513:name=="single8"?512:95),"libheif grid/clap dimensions");
  heif_color_profile_nclx* color=nullptr;checked(heif_image_handle_get_nclx_color_profile(raw,&color));
  require(color && color->color_primaries==(adaptive||name=="single8"?12:9) &&
      color->transfer_characteristics==(adaptive||name=="single8"?13:grid?18:16) &&
      color->matrix_coefficients==(adaptive||name=="single8"?1:9) && color->full_range_flag,
      "libheif nclx differs");
  heif_nclx_color_profile_free(color);
  require((heif_image_handle_get_raw_color_profile_size(raw)>0)==adaptive,"Adaptive P3 ICC presence");
  heif_content_light_level light{};
  const bool has_light=heif_image_handle_get_content_light_level(raw,&light)!=0;
  require(has_light==(!adaptive && name!="single8"),"libheif clli presence");
  if(has_light)require(light.max_content_light_level==1000 && light.max_pic_average_light_level==400,"libheif clli values");
  require(heif_image_handle_get_luma_bits_per_pixel(raw)==(name=="single8"||name=="adaptive8-grid"?8:10),
          "libheif hvcC bit depth");
  std::cout<<name<<": libheif opened "<<count<<" items, "<<refs.size()<<" reference sets\n";
}
}
int main(){try{for(const auto& name:writer_fixture::names())check(name);}
catch(const std::exception& error){std::cerr<<"heif_writer_interop_test: "<<error.what()<<'\n';return 1;}}

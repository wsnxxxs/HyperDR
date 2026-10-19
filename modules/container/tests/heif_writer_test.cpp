#include "heif_writer_fixture.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "internal/boxes.hpp"
#include "internal/hevc_bits.hpp"
#include "internal/items.hpp"
#include "internal/write_limits.hpp"
#include <array>
#include <iostream>
#include <fstream>
#include <sstream>
#include <map>
#include <pthread.h>

namespace {
using namespace hyperdr;
using namespace hyperdr::container;
using writer_fixture::sequence;
void require(bool okay, const char* message) { if (!okay) throw std::runtime_error(message); }
template<class Function> void rejects(Function fn) {
  try { fn(); } catch (const std::invalid_argument&) { return; }
  throw std::runtime_error("invalid writer input accepted");
}
// Rebuilds a NAL from its header and an edited RBSP, inserting emulation prevention.
Bytes nal_from_rbsp(const Bytes& nal,const Bytes& payload) {
  Bytes out(nal.begin(),nal.begin()+2);unsigned zeroes=0;
  for(const auto value:payload) {
    if(zeroes==2 && value<=3){out.push_back(3);zeroes=0;}
    out.push_back(value);zeroes=value?0:zeroes+1;
  }
  return out;
}
Bytes with_rbsp_bits(const Bytes& nal,std::size_t index,std::uint8_t bits) {
  auto payload=rbsp(nal);payload.at(index)|=bits;return nal_from_rbsp(nal,payload);
}
template<class Function> std::string rejection(Function fn) {
  try { fn(); } catch (const std::invalid_argument& e) { return e.what(); }
  throw std::runtime_error("invalid writer input accepted");
}
void parameter_corpus() {
  std::ifstream input(writer_fixture::root()/"parameter-cases.txt");
  require(input.good(), "missing independent parameter corpus");
  std::string line;unsigned count=0,legal_count=0;
  const auto unhex=[](const std::string& text) {
    require(text.size()%2==0,"odd parameter hex length");Bytes bytes;
    for(std::size_t i=0;i<text.size();i+=2)
      bytes.push_back(static_cast<std::uint8_t>(std::stoul(text.substr(i,2),nullptr,16)));
    return bytes;
  };
  while(std::getline(input,line)) {
    std::istringstream fields(line);std::string name,v,s,p;int legal=-1;
    require(static_cast<bool>(fields>>name>>legal>>v>>s>>p),"malformed parameter case");
    bool accepted=true;
    try {(void)make_hevc_configuration(unhex(v),unhex(s),unhex(p));}
    catch(const std::invalid_argument&){accepted=false;}
    if(accepted!=(legal==1))throw std::runtime_error("parameter corpus mismatch: "+name);
    ++count;legal_count+=legal==1;
  }
  require(count==47 && legal_count==36,"incomplete independent parameter corpus");
}
void framing() {
  const Bytes annex{0,0,0,1,0x40,1,0x80,0,0,1,0x26,1,0x80,0,0};
  const Bytes expected{0,0,0,3,0x40,1,0x80,0,0,0,3,0x26,1,0x80};
  require(hevc_annexb_to_sample(annex) == expected, "Annex-B framing/trailing zero handling");
  require(hevc_annexb_to_sample(hevc_sample_to_annexb(expected)) == expected, "NAL framing round trip");
  for (const Bytes& bad : {Bytes{}, Bytes{0,0,0,0}, Bytes{0,0,1}, Bytes{0,0,1,0x26,0,0x80},
       Bytes{1,0,0,1,0x26,1,0x80}, Bytes{0,0,1,0xA6,1,0x80}, Bytes{0,0,1,0x26,1,0x80,0,0,1}})
    rejects([&]{ (void)hevc_annexb_to_sample(bad); });
  for (const Bytes& bad : {Bytes{}, Bytes{0,0,0}, Bytes{0,0,0,0}, Bytes{0,0,0,8,0x26,1,0x80},
       Bytes{255,255,255,255}, Bytes{0,0,0,3,0x26,0,0x80}})
    rejects([&]{ (void)hevc_sample_to_annexb(bad); });
}
void configuration() {
  for (unsigned depth : {8U,10U}) {
    auto encoded = sequence(depth,1);
    const auto config = make_hevc_configuration(encoded.vps,encoded.sps,encoded.pps);
    require(config.width==512 && config.height==512 && config.bit_depth==depth && config.chroma_format==1,
            "SPS configuration fields");
    require(config.record.size()>23 && config.record[0]==1 && (config.record[21]&3)==3 && config.record[22]==3,
            "hvcC fixed header");
    std::size_t at=23;
    for (const auto* set : {&encoded.vps,&encoded.sps,&encoded.pps}) {
      require((config.record[at]&0x80) && be16(config.record,at+1)==1, "hvcC complete array");
      const auto size=be16(config.record,at+3);at+=5;
      require(size==set->size() && Bytes(config.record.begin()+at,config.record.begin()+at+size)==*set,
              "hvcC preserves parameter bytes");
      at+=size;
    }
    require(at==config.record.size(),"hvcC trailing bytes");
    const auto make=[&](const std::array<Bytes,3>& sets){
      return make_hevc_configuration(sets[0],sets[1],sets[2]);
    };
    const std::array<Bytes,3> complete{encoded.vps,encoded.sps,encoded.pps};
    require(nal_from_rbsp(encoded.vps,rbsp(encoded.vps))==encoded.vps &&
            nal_from_rbsp(encoded.sps,rbsp(encoded.sps))==encoded.sps,"emulation prevention round trip");
    for (std::size_t set=0;set<3;++set) {
      // Every proper prefix lacks syntax after the hvcC fields, so none is complete.
      for (std::size_t size=0;size<complete[set].size();++size) {
        auto sets=complete;sets[set].resize(size);
        rejects([&]{(void)make(sets);});
      }
      for (const std::uint8_t extra : {0x00,0x80}) {
        auto sets=complete;sets[set].push_back(extra);
        rejects([&]{(void)make(sets);});
      }
      auto sets=complete;sets[set].back()=0; // drop the rbsp stop bit
      rejects([&]{(void)make(sets);});
      sets=complete;sets[set].resize(65536);
      rejects([&]{(void)make(sets);});
      // Any single flipped bit is either a valid set or a clean rejection.
      for (std::size_t bit=0;bit<complete[set].size()*8;++bit) {
        sets=complete;sets[set][bit/8]^=static_cast<std::uint8_t>(0x80>>(bit%8));
        try { (void)make(sets); } catch (const std::invalid_argument&) {}
      }
    }
    // Main10 syntax (profile 2, or Main with compatibility flag 2 as both
    // fixtures carry) allows one_picture_only_constraint_flag, bit 0x10 of the
    // seventh profile byte. Every other reserved bit and general_inbld_flag stay zero.
    require(config.record[2]&0x20,"fixtures declare Main10 compatibility");
    for (const auto [byte,bits] : {std::pair{6U,std::uint8_t{0x10}},std::pair{10U,std::uint8_t{0x10}},
                                   std::pair{10U,std::uint8_t{0x01}}}) {
      const auto vps=with_rbsp_bits(encoded.vps,4+byte,bits),sps=with_rbsp_bits(encoded.sps,1+byte,bits);
      if (byte==6) {
        const auto flagged=make_hevc_configuration(vps,sps,encoded.pps);
        require(flagged.record[1+byte]==bits && flagged.bit_depth==depth,
                "Main10 one_picture_only_constraint_flag carried into hvcC");
      } else {
        rejects([&]{(void)make_hevc_configuration(vps,sps,encoded.pps);});
      }
    }
    auto sets=complete;sets[0][2]^=0x10; // vps_video_parameter_set_id no longer matches the SPS
    rejects([&]{(void)make(sets);});
    auto wrong=encoded.pps;wrong[0]=0x40;
    rejects([&]{(void)make_hevc_configuration(encoded.vps,encoded.sps,wrong);});
  }
}
void invalid_images() {
  require(bounded_heif_add(0xFFFFFFFEULL,1)==0xFFFFFFFFULL,"32-bit length boundary");
  rejects([]{(void)bounded_heif_add(0xFFFFFFFFULL,1);});
  rejects([]{(void)bounded_heif_add(UINT64_MAX,1);});
  rejects([]{(void)bounded_heif_add(1,UINT64_MAX);});
  auto seq=sequence(8,1);
  HeifEncodedImage image{seq,512,512,{},std::nullopt,{}};
  for (const auto size : {0U,131073U,0xFFFFFFFFU}) {
    auto bad=image;bad.width=size;
    rejects([&]{(void)write_heif(bad);});
  }
  auto bad=image;bad.width=513;
  rejects([&]{(void)write_heif(bad);});
  auto icc=read_binary_file(writer_fixture::root()/"display-p3.icc");
  bad=image;bad.display_p3_icc=icc;bad.color={9,16,9,true};
  rejects([&]{(void)write_heif(bad);});
  auto broken=icc;broken[36]=0;
  bad=image;bad.display_p3_icc=broken;
  rejects([&]{(void)write_heif(bad);});
  bad=image;bad.light=HeifContentLight{100,200};
  rejects([&]{(void)write_heif(bad);});
  HeifWriteOptions options; options.gain_metadata=writer_fixture::metadata(false);
  rejects([&]{(void)write_heif(image,nullptr,options);});
  rejects([&]{(void)write_heif(image,&image,options);}); // missing P3 ICC
  options={};options.xmp.resize(4U*1024*1024+1);
  rejects([&]{(void)write_heif(image,nullptr,options);});
  for (const Bytes& malformed : {Bytes{},Bytes{0,0,0,4,0x26,1},Bytes{0,0,0,3,0x02,1,0x80},
       Bytes{0,0,0,3,0x40,1,0x80},Bytes{0,0,0,3,0x26,0,0x80}}) {
    auto bad_seq=sequence(8,1);bad_seq.samples[0]=malformed;
    HeifEncodedImage bad_image{bad_seq,512,512,{},std::nullopt,{}};
    rejects([&]{(void)write_heif(bad_image);});
  }
  auto many=sequence(8,4097);
  HeifEncodedImage too_many{many,512*65,512*65,{},std::nullopt,{}};
  rejects([&]{(void)write_heif(too_many);});
  CancelToken cancel;cancel.request();CancelScope scope(&cancel);
  try { (void)write_heif(image); } catch (const Cancelled&) { return; }
  throw std::runtime_error("writer ignored cancellation");
}

void structure(const std::string& name,const Bytes& bytes) {
  const auto inspection=inspect_heif(bytes);
  require(inspection.structurally_valid,"inspect rejected writer output");
  const bool adaptive=name.starts_with("adaptive");
  require(inspection.has_tmap_item==adaptive && inspection.has_exif==adaptive && inspection.has_xmp==adaptive,
          "metadata item presence");
  if (adaptive) {
    require(inspection.gain_map_has_auxl_reference && inspection.has_altr_group && inspection.has_data_information,
            "Adaptive references/groups");
    require(extract_tmap_payload(bytes)==serialize_tmap_payload(writer_fixture::metadata(name=="adaptive8-grid")),
            "authored channel/offset/headroom metadata changed");
  }
  const auto tops=children(bytes,0,bytes.size());
  require(tops.size()==3 && tops[0].type=="ftyp" && tops[1].type=="meta" && tops[2].type=="mdat",
          "writer must emit once: ftyp/meta/mdat");
  auto meta=std::span(bytes).subspan(tops[1].offset,tops[1].size);
  Bytes iinf,iloc,ipma; std::vector<Box> props;std::map<unsigned,std::string> types;
  for (auto box:children(meta,12,meta.size())) {
    if(box.type=="iinf")iinf=slice(meta,box);
    if(box.type=="iloc")iloc=slice(meta,box);
    if(box.type=="iprp")for(auto child:children(meta,box.offset+8,box.offset+box.size)) {
      if(child.type=="ipma")ipma=slice(meta,child);
      if(child.type=="ipco")props=children(meta,child.offset+8,child.offset+child.size);
    }
  }
  for(const auto& property:props)require(property.type!="clap","writer must crop with grid, never clap");
  for(const auto& item:parse_iinf(iinf)) {
    types[item.id]=item.type;
    const bool hidden=item.type=="Exif" || item.type=="mime" ||
        ((item.type=="hvc1" || item.type=="grid") && item.id!=1);
    require(bool(item.infe[11]&1)==hidden,"hidden tiles/gain/metadata flags");
  }
  // Every stored extent is within mdat, and the declared item count agrees.
  std::size_t at=16;
  const auto item_count=be16(iloc,14);
  require(item_count==types.size(),"iloc/iinf item count");
  for(unsigned i=0;i<item_count;++i) {
    const auto id=be16(iloc,at); const auto offset=be32(iloc,at+8),size=be32(iloc,at+12);at+=16;
    require(types.contains(id) && offset>=tops[2].offset+8 && offset<=bytes.size() && size<=bytes.size()-offset,
            "item extent outside mdat");
  }
  require(at==iloc.size(),"iloc trailing data");
  unsigned hvcc_count=0;
  for(const auto& property:props)if(property.type=="hvcC")++hvcc_count;
  require(hvcc_count==(name=="adaptive8-grid"?2U:1U),"hvcC must be shared, not copied per tile");
  at=16;
  const bool wide=ipma[11]&1;
  std::map<unsigned,unsigned> tile_configuration_counts;
  for(unsigned i=0;i<be32(ipma,12);++i) {
    const auto id=be16(ipma,at);const auto count=ipma[at+2];at+=3;unsigned hvcc=0;
    for(unsigned j=0;j<count;++j) {
      const unsigned raw=wide?be16(ipma,at):ipma[at];at+=wide?2:1;
      const auto index=raw&(wide?0x7FFF:0x7F);
      require(index && index<=props.size(),"ipma property index");
      const auto& property=props[index-1];
      if(property.type=="hvcC")hvcc=index;
      if(property.type=="colr" && be32(meta,property.offset+8)==0x6E636C78)
        require(raw&(wide?0x8000:0x80),"authoritative nclx must be essential");
    }
    if(types[id]=="hvc1") {
      require(hvcc,"hvc1 missing configuration");++tile_configuration_counts[hvcc];
    } else require(!hvcc,"derived image must not carry hvcC");
  }
  if(name=="grid10-hlg")require(tile_configuration_counts.begin()->second==4,"grid leaves share config");
  if(name=="adaptive8-grid")for(auto [index,count]:tile_configuration_counts)require(count==4,"pair leaves share config");
}
struct StackResult { std::vector<Bytes> files; std::exception_ptr error; };
void* on_small_stack(void* context) {
  auto& result=*static_cast<StackResult*>(context);
  try { for(const auto& name:writer_fixture::names())result.files.push_back(writer_fixture::file(name)); }
  catch(...){result.error=std::current_exception();}
  return nullptr;
}
void small_stack(const std::vector<Bytes>& expected) {
  StackResult result;pthread_attr_t attr;
  require(pthread_attr_init(&attr)==0,"pthread_attr_init");
  require(pthread_attr_setstacksize(&attr,512*1024)==0,"pthread stack size");
  pthread_t thread;const auto status=pthread_create(&thread,&attr,on_small_stack,&result);
  pthread_attr_destroy(&attr);require(status==0,"pthread_create");
  require(pthread_join(thread,nullptr)==0,"pthread_join");
  if(result.error)std::rethrow_exception(result.error);
  require(result.files==expected,"512KB stack writer output differs");
}
void grid_limits() {
  auto wide=sequence(8,256);
  const auto bytes=write_heif(HeifEncodedImage{wide,131072,512,{},std::nullopt,{}});
  structure("large-grid",bytes);
  const auto top=children(bytes,0,bytes.size());
  const auto start=top.back().offset+8;
  require(bytes[start]==0 && bytes[start+1]==1 && bytes[start+2]==0 && bytes[start+3]==255 &&
      be32(bytes,start+4)==131072 && be32(bytes,start+8)==512,"32-bit grid dimensions and 256-column limit");
  auto maximum=sequence(8,4096);
  structure("maximum-grid",write_heif(HeifEncodedImage{maximum,32768,32768,{},std::nullopt,{}}));
  // 2048 base + 2048 gain tiles: the most an Adaptive file may carry. The
  // tmap/inspect readers must accept every item the writer can emit.
  const auto icc=read_binary_file(writer_fixture::root()/"display-p3.icc");
  const auto base_tiles=sequence(8,2048),gain_tiles=sequence(10,2048),wide_gain_tiles=sequence(10,65*32);
  HeifEncodedImage base{base_tiles,32768,16384,{},std::nullopt,icc};
  HeifEncodedImage gain{gain_tiles,32768,16384,{2,2,1,true},std::nullopt,{}};
  for (const bool metadata : {false,true}) {
    HeifWriteOptions options;options.gain_metadata=writer_fixture::metadata(true);
    if (metadata) {
      PhotoMetadata capture;capture.make="HyperDR";
      options.exif=make_minimal_exif(capture);options.xmp=make_xmp(capture,3,true);
    }
    const auto bytes=write_heif(base,&gain,options);
    const auto inspection=inspect_heif(bytes);
    require(inspection.structurally_valid && inspection.has_tmap_item && inspection.has_exif==metadata &&
            inspection.has_xmp==metadata && inspection.gain_map_has_auxl_reference && inspection.has_altr_group,
            "4096-tile Adaptive output fails inspection");
    require(extract_tmap_payload(bytes)==serialize_tmap_payload(*options.gain_metadata),
            "4096-tile Adaptive tmap extraction");
    const auto tops=children(bytes,0,bytes.size());
    for (auto box:children(bytes,tops[1].offset+12,tops[1].offset+tops[1].size))
      if (box.type=="iloc")
        require(be16(bytes,box.offset+14)==4096+3+(metadata?2:0),"4096-tile Adaptive item count");
  }
  // One more gain column pushes the pair past 4096 tiles.
  HeifEncodedImage wider{wide_gain_tiles,33280,16384,{2,2,1,true},std::nullopt,{}};
  HeifWriteOptions options;options.gain_metadata=writer_fixture::metadata(true);
  require(rejection([&]{(void)write_heif(base,&wider,options);}).find("4096 coded tiles")!=std::string::npos,
          "tile budget error must name the 4096-tile limit");
}
}
int main(int argc,char** argv) {
  try {
    framing();configuration();parameter_corpus();invalid_images();
    std::vector<Bytes> files;
    for(const auto& name:writer_fixture::names()) {
      auto bytes=writer_fixture::file(name);structure(name,bytes);
      const auto path=writer_fixture::root()/(name+".heic");
      if(argc==2 && std::string_view(argv[1])=="--write-goldens")write_binary_file_atomic(path,bytes,true);
      else require(bytes==read_binary_file(path),"HEIF signed-in golden mismatch");
      files.push_back(std::move(bytes));
    }
    small_stack(files);grid_limits();
    std::cout<<"heif_writer_test passed: 5 goldens, NAL/config bounds, 512KB stack\n";
  } catch(const std::exception& e){std::cerr<<"heif_writer_test: "<<e.what()<<'\n';return 1;}
}

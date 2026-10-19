#pragma once
// Deliberately non-product HEIF variants for decoder regressions. Pixel streams
// come from VT; start from write_heif, then alter only the format being tested.
#include <algorithm>
#include <functional>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>
namespace heif_fixture {
using Bytes=std::vector<std::uint8_t>;
inline unsigned get(std::span<const std::uint8_t> b,std::size_t at,unsigned n) {
  if(at+n>b.size())throw std::runtime_error("truncated fixture box");unsigned v=0;
  for(unsigned i=0;i<n;++i)v=(v<<8)|b[at+i];return v;
}
inline void put(Bytes& b,std::size_t at,unsigned v,unsigned n) {
  if(at+n>b.size())throw std::runtime_error("fixture field bounds");
  for(unsigned i=0;i<n;++i)b[at+i]=v>>(8*(n-i-1));
}
struct Box {std::string type;Bytes data;};
inline std::vector<Box> parse(std::span<const std::uint8_t> b) {
  std::vector<Box> out;for(std::size_t p=0;p<b.size();) {
    auto n=get(b,p,4);if(n<8||n>b.size()-p)throw std::runtime_error("fixture box bounds");
    out.push_back({std::string(b.begin()+p+4,b.begin()+p+8),Bytes(b.begin()+p+8,b.begin()+p+n)});p+=n;
  }return out;
}
inline Bytes serialize(const std::vector<Box>& boxes) {
  Bytes out;for(auto& box:boxes){auto p=out.size();out.resize(p+8);put(out,p,box.data.size()+8,4);
    std::copy(box.type.begin(),box.type.end(),out.begin()+p+4);out.insert(out.end(),box.data.begin(),box.data.end());}return out;
}
inline void children(Box& b,unsigned skip,const std::function<void(std::vector<Box>&)>& f) {
  auto parts=parse(std::span(b.data).subspan(skip));f(parts);auto bytes=serialize(parts);b.data.resize(skip);b.data.insert(b.data.end(),bytes.begin(),bytes.end());
}
// Relocate all iloc extents after any metadata-size change. Optional sample is
// only for the single-item 4:2:2 fixture; it must not affect product packaging.
inline Bytes edit(Bytes bytes,const std::function<void(std::vector<Box>&)>& f,const Bytes* sample=nullptr) {
  auto top=parse(bytes);auto& meta=*std::find_if(top.begin(),top.end(),[](auto& b){return b.type=="meta";});auto old=meta.data.size();
  children(meta,4,f);const auto delta=std::int64_t(meta.data.size())-old;
  children(meta,4,[&](auto& list){for(auto& b:list)if(b.type=="iloc") {
    if(b.data[0]!=1||b.data[4]!=0x44)throw std::runtime_error("unexpected writer iloc");
    auto count=get(b.data,6,2);if(sample&&count!=1)throw std::runtime_error("422 fixture must be one item");
    for(unsigned j=0;j<count;++j){auto p=8+16*j;put(b.data,p+8,get(b.data,p+8,4)+delta,4);if(sample)put(b.data,p+12,sample->size(),4);}
  }});
  if(sample)for(auto& b:top)if(b.type=="mdat")b.data=*sample;
  return serialize(top);
}
inline void properties(std::vector<Box>& meta,const std::function<void(Box&)>& f) {
  for(auto& b:meta)if(b.type=="iprp")children(b,0,[&](auto& iprp){for(auto& c:iprp)if(c.type=="ipco")children(c,0,[&](auto& props){for(auto& p:props)f(p);});});
}
} // namespace heif_fixture

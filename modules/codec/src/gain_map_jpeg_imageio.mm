// ImageIO translates legacy XMP into ISO metadata. No hdrgm fields are parsed here.
#include "internal/gain_map_jpeg.hpp"
#include "internal/budget.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include <ImageIO/ImageIO.h>
#include <CoreVideo/CoreVideo.h>
#include <map>
#include <type_traits>
#include <exception>
#include <memory>
#include <string>
#include <cmath>
#include <cstring>
#include <limits>

namespace hyperdr::codec {
namespace {
thread_local void (*auxiliary_hook)(bool) noexcept = nullptr;
struct Release { void operator()(const void* p) const { if(p) CFRelease(p); } };
template<class T> using CF = std::unique_ptr<std::remove_pointer_t<T>,Release>;
std::string string(CFStringRef value) {
  if(!value) throw std::runtime_error("ImageIO gain-map string is missing");
  const auto n=CFStringGetMaximumSizeForEncoding(CFStringGetLength(value),kCFStringEncodingUTF8)+1;
  if(n>4096)throw std::runtime_error("ImageIO gain-map string is too long");
  std::string out(n,'\0');
  if(!CFStringGetCString(value,out.data(),out.size(),kCFStringEncodingUTF8))throw std::runtime_error("invalid ImageIO gain-map string");
  out.resize(std::strlen(out.c_str()));return out;
}
double number(CFDictionaryRef dictionary,CFStringRef key) {
  auto value=CFDictionaryGetValue(dictionary,key);double out;
  if(!value || CFGetTypeID(value)!=CFNumberGetTypeID() ||
     !CFNumberGetValue(static_cast<CFNumberRef>(value),kCFNumberDoubleType,&out)||!std::isfinite(out))
    throw std::runtime_error("invalid ImageIO gain-map description");
  return out;
}
}
GainMapRead read_gain_map_jpeg_imageio(const std::vector<std::uint8_t>& bytes) {
 @autoreleasepool {
  check_cancelled();
  auto normalized=normalize_gain_map_jpeg_mpf(bytes);
  const auto& input=normalized.empty() ? bytes : normalized;
  check_cancelled();
  CF<CFDataRef> data(CFDataCreateWithBytesNoCopy(nullptr,input.data(),input.size(),kCFAllocatorNull));
  if(!data)throw std::bad_alloc();
  CF<CGImageSourceRef> source(CGImageSourceCreateWithData(data.get(),nullptr));
  if(!source)throw std::runtime_error("ImageIO cannot open XMP gain-map JPEG");
  if(auxiliary_hook)auxiliary_hook(true);
  CF<CFDictionaryRef> info(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source.get(),0,kCGImageAuxiliaryDataTypeISOGainMap));
  if(auxiliary_hook)auxiliary_hook(false);
  check_cancelled();
  if(!info)throw std::runtime_error("ImageIO did not expose an ISO gain map for XMP input");
  auto pixels=static_cast<CFDataRef>(CFDictionaryGetValue(info.get(),kCGImageAuxiliaryDataInfoData));
  auto desc=static_cast<CFDictionaryRef>(CFDictionaryGetValue(info.get(),kCGImageAuxiliaryDataInfoDataDescription));
  auto metadata=static_cast<CGImageMetadataRef>(CFDictionaryGetValue(info.get(),kCGImageAuxiliaryDataInfoMetadata));
  if(!pixels||CFGetTypeID(pixels)!=CFDataGetTypeID() || !desc||CFGetTypeID(desc)!=CFDictionaryGetTypeID() ||
      !metadata||CFGetTypeID(metadata)!=CGImageMetadataGetTypeID())throw std::runtime_error("ImageIO gain-map auxiliary data is incomplete");
  auto integer=[&](CFStringRef key)->std::uint32_t {
    const auto v=number(desc,key);
    if(v<1||v>std::numeric_limits<std::uint32_t>::max()||std::floor(v)!=v)throw std::runtime_error("invalid ImageIO gain-map dimension");
    return v;
  };
  const auto w=integer(CFSTR("Width")),h=integer(CFSTR("Height")),stride=integer(CFSTR("BytesPerRow")),format=integer(CFSTR("PixelFormat"));
  if(!raster_budget_ok(w,h))throw std::runtime_error("ImageIO gain map exceeds decode budget");
  unsigned channels=0,components=0,red=0,green=1,blue=2;
  if(format==kCVPixelFormatType_OneComponent8){channels=components=1;}
  else if(format==kCVPixelFormatType_24RGB){channels=components=3;}
  else if(format==kCVPixelFormatType_32RGBA){channels=3;components=4;}
  else if(format==kCVPixelFormatType_32BGRA){channels=3;components=4;red=2;blue=0;}
  else throw std::runtime_error("unsupported ImageIO gain-map pixel format");
  if(stride<static_cast<std::uint64_t>(w)*components || static_cast<std::uint64_t>(stride)*h>CFDataGetLength(pixels))
    throw std::runtime_error("truncated ImageIO gain-map pixels");
  std::map<std::string,std::string> tags;
  auto* output=&tags;
  const void* optionKeys[]{kCGImageMetadataEnumerateRecursively};
  const void* optionValues[]{kCFBooleanTrue};
  CF<CFDictionaryRef> options(CFDictionaryCreate(nullptr,optionKeys,optionValues,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));
  std::exception_ptr failure;
  auto* error=&failure;
  CGImageMetadataEnumerateTagsUsingBlock(metadata,nullptr,options.get(),^(CFStringRef path,CGImageMetadataTagRef tag) {
    try {
    CF<CFTypeRef> value(CGImageMetadataTagCopyValue(tag));
    if(value && CFGetTypeID(value.get())==CFStringGetTypeID())
      output->emplace(string(path),string(static_cast<CFStringRef>(value.get())));
    return true;
    }catch(...){*error=std::current_exception();return false;}
  });
  if(failure)std::rethrow_exception(failure);
  auto field=[&](const std::string& key)->std::string {
    const auto it=tags.find("HDRToneMap:"+key);
    if(it==tags.end())throw std::runtime_error("ImageIO ISO gain-map field is missing: "+key);
    return it->second;
  };
  auto rational=[&](const std::string& key)->Rational {
    const auto text=field(key);std::size_t used=0;const auto v=std::stod(text,&used);
    // ImageIO exposes six decimal places. Round once to that precision,
    // preserving signed coding values and bounding the integer conversion.
    if(used!=text.size()||!std::isfinite(v)||std::abs(v)>2000)throw std::runtime_error("invalid ImageIO ISO gain-map number");
    return {static_cast<std::int32_t>(std::llround(v*1000000)),1000000};
  };
  GainMapRead result;
  auto& m=result.metadata;
  if(field("Version")!="1")throw std::runtime_error("unsupported ImageIO ISO gain-map metadata version");
  m.base_headroom=rational("BaseHeadroom");m.alternate_headroom=rational("AlternateHeadroom");
  const auto base=field("BaseColorIsWorkingColor");
  if(base!="True"&&base!="False")throw std::runtime_error("invalid ImageIO gain-map working colour space");
  m.use_base_color_space=base=="True";
  auto channel=[&](unsigned c) {
    const auto prefix="ChannelMetadata["+std::to_string(c)+"].";
    return GainMapChannelMetadata{rational(prefix+"GainMapMin"),rational(prefix+"GainMapMax"),rational(prefix+"Gamma"),
      rational(prefix+"BaseOffset"),rational(prefix+"AlternateOffset")};
  };
  const bool second=tags.contains("HDRToneMap:ChannelMetadata[1].GainMapMin");
  const bool third=tags.contains("HDRToneMap:ChannelMetadata[2].GainMapMin");
  if(second!=third)throw std::runtime_error("incomplete ImageIO channel metadata");
  const unsigned metadata_channels=third?3:1;
  channels=std::max(channels,metadata_channels);
  if(channels==1){auto c=channel(0);m.gain_min=c.gain_min;m.gain_max=c.gain_max;m.gamma=c.gamma;m.base_offset=c.base_offset;m.alternate_offset=c.alternate_offset;}
  else {m.flags|=0x80;for(unsigned c=0;c<3;++c)m.channels.push_back(channel(metadata_channels==1?0:c));}
  validate_gain_map_metadata(m);
  result.pixels=FloatImage(w,h,channels);
  const auto* codes=CFDataGetBytePtr(pixels);
  parallel_for_rows(h,[&](std::uint32_t y){
    for(unsigned x=0;x<w;++x){const auto* p=codes+static_cast<std::size_t>(y)*stride+x*components;
      if(channels==1)result.pixels.at(x,y,0)=p[0]/255.F;
      else {result.pixels.at(x,y,0)=p[components==1?0:red]/255.F;result.pixels.at(x,y,1)=p[components==1?0:green]/255.F;result.pixels.at(x,y,2)=p[components==1?0:blue]/255.F;}
    }
  });
  check_cancelled();return result;
 }
}
}

namespace hyperdr::codec::testing {
void set_imageio_gain_map_hook(void (*hook)(bool) noexcept) { auxiliary_hook=hook; }
}

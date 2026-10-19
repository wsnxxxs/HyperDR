#pragma once
// VT's 4:2:2 profile is a decoder test only: product exports remain Main/Main10
// 4:2:0, so their writer deliberately rejects this profile.
#include "heif_fixture_edit.hpp"
#include "hevc/testing.hpp"
#include <VideoToolbox/VideoToolbox.h>
#include <exception>
namespace heif_fixture {
struct Vt422 {
  VTCompressionSessionRef session{};CVPixelBufferRef pixel{};
  hyperdr::codec::hevc::EncodedSequence stream;Bytes configuration;std::exception_ptr error;
  ~Vt422(){if(session){VTCompressionSessionInvalidate(session);CFRelease(session);}if(pixel)CFRelease(pixel);}
};
inline void status(OSStatus value){if(value)throw std::runtime_error("VT 4:2:2 fixture status "+std::to_string(value));}
inline void output422(void* context,void*,OSStatus result,VTEncodeInfoFlags,CMSampleBufferRef sample) {
  auto& s=*static_cast<Vt422*>(context);
  try {
    status(result);if(!sample)throw std::runtime_error("VT 422 missing sample");
    auto format=CMSampleBufferGetFormatDescription(sample);int length=0;std::size_t count=0;
    status(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,0,nullptr,nullptr,&count,&length));
    for(std::size_t i=0;i<count;++i){const std::uint8_t* p=nullptr;std::size_t n=0;
      status(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,i,&p,&n,nullptr,nullptr));
      const auto t=(p[0]>>1)&63;auto* dest=t==32?&s.stream.vps:t==33?&s.stream.sps:t==34?&s.stream.pps:nullptr;if(dest)dest->assign(p,p+n);
    }
    auto atoms=static_cast<CFDictionaryRef>(CMFormatDescriptionGetExtension(format,kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
    if(!atoms)throw std::runtime_error("VT 422 missing format atoms");
    auto hvcc=static_cast<CFDataRef>(CFDictionaryGetValue(atoms,CFSTR("hvcC")));
    if(!hvcc)throw std::runtime_error("VT 422 missing hvcC");
    s.configuration.assign(CFDataGetBytePtr(hvcc),CFDataGetBytePtr(hvcc)+CFDataGetLength(hvcc));
    auto block=CMSampleBufferGetDataBuffer(sample);Bytes bytes(CMBlockBufferGetDataLength(block));
    status(CMBlockBufferCopyDataBytes(block,0,bytes.size(),bytes.data()));
    s.stream.samples.push_back(hyperdr::codec::hevc::testing::repack_sample(bytes,length,s.stream));
  }catch(...){s.error=std::current_exception();}
}
inline Bytes hlg422(const hyperdr::FloatImage& linear) {
  namespace h=hyperdr::codec::hevc;Vt422 s;
  status(VTCompressionSessionCreate(nullptr,linear.width,linear.height,kCMVideoCodecType_HEVC,nullptr,nullptr,nullptr,output422,&s,&s.session));
  status(VTSessionSetProperty(s.session,kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_HEVC_Main42210_AutoLevel));
  status(VTSessionSetProperty(s.session,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse));
  status(VTSessionSetProperty(s.session,kVTCompressionPropertyKey_ColorPrimaries,kCVImageBufferColorPrimaries_ITU_R_2020));
  status(VTSessionSetProperty(s.session,kVTCompressionPropertyKey_TransferFunction,kCVImageBufferTransferFunction_ITU_R_2100_HLG));
  status(VTSessionSetProperty(s.session,kVTCompressionPropertyKey_YCbCrMatrix,kCVImageBufferYCbCrMatrix_ITU_R_2020));
  float q=.95F;auto number=CFNumberCreate(nullptr,kCFNumberFloatType,&q);
  auto setting=VTSessionSetProperty(s.session,kVTCompressionPropertyKey_Quality,number);CFRelease(number);status(setting);
  status(VTCompressionSessionPrepareToEncodeFrames(s.session));
  status(CVPixelBufferCreate(nullptr,linear.width,linear.height,kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,nullptr,&s.pixel));
  status(CVPixelBufferLockBaseAddress(s.pixel,0));
  const auto encoded=[&](unsigned x,unsigned y){auto wide=hyperdr::p3_to_rec2020(linear.at(x,y,0),linear.at(x,y,1),linear.at(x,y,2));
    for(auto& v:wide)v=std::max(0.F,v);return hyperdr::hlg_encode(wide);};
  const auto code=[](float value){return std::uint16_t(std::lround(std::clamp(value,0.F,1.F)*1023))<<6;};
  for(unsigned y=0;y<linear.height;++y){
    auto* Y=reinterpret_cast<std::uint16_t*>(static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(s.pixel,0))+y*CVPixelBufferGetBytesPerRowOfPlane(s.pixel,0));
    auto* uv=reinterpret_cast<std::uint16_t*>(static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(s.pixel,1))+y*CVPixelBufferGetBytesPerRowOfPlane(s.pixel,1));
    for(unsigned x=0;x<linear.width;x+=2){float cb=0,cr=0;
      for(unsigned i=0;i<2;++i){auto rgb=encoded(std::min(x+i,linear.width-1),y);float l=.2627F*rgb[0]+.6780F*rgb[1]+.0593F*rgb[2];
        if(x+i<linear.width)Y[x+i]=code(l);cb+=(rgb[2]-l)/1.8814F;cr+=(rgb[0]-l)/1.4746F;}
      uv[x]=code(cb*.5F+512.F/1023);uv[x+1]=code(cr*.5F+512.F/1023);
    }
  }
  status(CVPixelBufferUnlockBaseAddress(s.pixel,0));
  status(VTCompressionSessionEncodeFrame(s.session,s.pixel,CMTimeMake(0,1),kCMTimeInvalid,nullptr,nullptr,nullptr));
  status(VTCompressionSessionCompleteFrames(s.session,kCMTimeInvalid));if(s.error)std::rethrow_exception(s.error);
  if(s.stream.samples.size()!=1)throw std::runtime_error("VT 422 must produce one image");
  h::EncodeParams params;params.main10=true;params.color={9,18,9};
  auto dummy=h::encode(1,[](auto,h::YuvTile& tile){std::fill(tile.luma.begin(),tile.luma.end(),0);std::fill(tile.chroma.begin(),tile.chroma.end(),0);},params);
  hyperdr::HeifEncodedImage image{dummy,512,512,{9,18,9,true},std::nullopt,{}};
  auto bytes=hyperdr::write_heif(image);
  return edit(bytes,[&](auto& meta){properties(meta,[&](Box& p){if(p.type=="hvcC")p.data=s.configuration;
    if(p.type=="ispe"){put(p.data,4,linear.width,4);put(p.data,8,linear.height,4);}});},&s.stream.samples[0]);
}
} // namespace heif_fixture

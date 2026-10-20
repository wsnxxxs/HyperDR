#include "metal_yuv.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/progress.hpp"
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <stdexcept>
#include <cstdlib>
#include <cstdio>

namespace hyperdr::codec::hevc {
namespace {
const char* source=R"MSL(
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)
struct Params { float kr,kg,kb,cb_scale,cr_scale,offset,max_code,storage_max; uint shift; };
float unit(float v) { return v>0.f?(v<1.f?v:1.f):0.f; }
float3 yuv(device const float* pixels,uint x,uint y,constant Params& p) {
  const uint i=(y*512+x)*3;
  const float r=unit(pixels[i]),g=unit(pixels[i+1]),b=unit(pixels[i+2]);
  const float l=p.kr*r+p.kg*g+p.kb*b;
  return float3(l,(b-l)*p.cb_scale,(r-l)*p.cr_scale);
}
float code(float v,constant Params& p) {
  return float(uint(round(unit(v)*p.max_code))<<p.shift)/p.storage_max;
}
kernel void convert(device const float* pixels [[buffer(0)]],constant Params& p [[buffer(1)]],
  texture2d<float,access::write> luma [[texture(0)]],
  texture2d<float,access::write> chroma [[texture(1)]],uint2 pos [[thread_position_in_grid]]) {
  if(any(pos>=uint2(256)))return;
  const uint x=pos.x*2,y=pos.y*2;
  const float3 a=yuv(pixels,x,y,p),b=yuv(pixels,x+1,y,p);
  const float3 c=yuv(pixels,x,y+1,p),d=yuv(pixels,x+1,y+1,p);
  luma.write(float4(code(a.x,p)),uint2(x,y));
  luma.write(float4(code(b.x,p)),uint2(x+1,y));
  luma.write(float4(code(c.x,p)),uint2(x,y+1));
  luma.write(float4(code(d.x,p)),uint2(x+1,y+1));
  // Match the CPU's vertical sums followed by the horizontal sum.
  const float cb=((a.y+c.y)+(b.y+d.y))*0.25f+p.offset;
  const float cr=((a.z+c.z)+(b.z+d.z))*0.25f+p.offset;
  chroma.write(float4(code(cb,p),code(cr,p),0,0),pos);
}
)MSL";
struct Params { float kr,kg,kb,cb_scale,cr_scale,offset,max_code,storage_max;std::uint32_t shift; };
}
struct MetalRgbTiles::State {
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  id<MTLComputePipelineState> pipeline;
  id<MTLBuffer> input;
  CVMetalTextureCacheRef cache{};
  ~State() { if(cache)CFRelease(cache); }
};
MetalRgbTiles::MetalRgbTiles():state_(std::make_unique<State>()) {
  @autoreleasepool {
    auto& s=*state_;s.device=MTLCreateSystemDefaultDevice();
    if(!s.device)throw std::runtime_error("Metal HEVC has no device");
    s.queue=[s.device newCommandQueue];
    MTLCompileOptions* options=[MTLCompileOptions new];
    options.mathMode=MTLMathModeSafe;
    options.mathFloatingPointFunctions=MTLMathFloatingPointFunctionsPrecise;
    NSError* error=nil;
    auto library=[s.device newLibraryWithSource:[NSString stringWithUTF8String:source] options:options error:&error];
    if(!library)throw std::runtime_error(std::string("Metal HEVC shader: ")+error.localizedDescription.UTF8String);
    s.pipeline=[s.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"convert"] error:&error];
    s.input=[s.device newBufferWithLength:std::size_t(kTileSize)*kTileSize*3*sizeof(float) options:MTLResourceStorageModeShared];
    if(!s.queue||!s.pipeline||!s.input||CVMetalTextureCacheCreate(kCFAllocatorDefault,nullptr,s.device,nullptr,&s.cache)!=kCVReturnSuccess)
      throw std::runtime_error("cannot allocate bounded Metal HEVC resources");
  }
}
MetalRgbTiles::~MetalRgbTiles()=default;
void MetalRgbTiles::convert(const TileGrid& grid,std::size_t index,const RgbRowReader& read,
                           int matrix,int depth,CVPixelBufferRef buffer) {
  if(index>=grid.count()||(depth!=8&&depth!=10)||(matrix!=1&&matrix!=9))
    throw std::invalid_argument("invalid Metal HEVC tile");
  @autoreleasepool {
    check_cancelled();auto& s=*state_;
    const auto x0=unsigned(index%grid.columns)*kTileSize,y0=unsigned(index/grid.columns)*kTileSize;
    const auto inside=std::min(kTileSize,grid.width-x0);
    auto* pixels=static_cast<float*>(s.input.contents);
    parallel_for_rows(kTileSize,[&](unsigned y) {
      auto* row=pixels+std::size_t(y)*kTileSize*3;
      read(std::min(y0+y,grid.height-1),x0,inside,row);
      for(unsigned x=inside;x<kTileSize;++x)std::copy_n(row+(inside-1)*3,3,row+x*3);
    });
    Params p{};p.kr=matrix==9?.2627f:.2126f;p.kg=matrix==9?.6780f:.7152f;p.kb=matrix==9?.0593f:.0722f;
    p.cb_scale=1.f/(2.f*(1.f-p.kb));p.cr_scale=1.f/(2.f*(1.f-p.kr));
    p.max_code=float((1u<<depth)-1);p.offset=float(1u<<(depth-1))/p.max_code;
    p.shift=depth==10?6:0;p.storage_max=depth==10?65535.f:255.f;
    CVMetalTextureRef views[2]{};
    auto release=[&] { for(auto v:views)if(v)CFRelease(v); };
    for(unsigned plane=0;plane<2;++plane) {
      const MTLPixelFormat format=depth==10?(plane?MTLPixelFormatRG16Unorm:MTLPixelFormatR16Unorm):(plane?MTLPixelFormatRG8Unorm:MTLPixelFormatR8Unorm);
      const auto usage=@{(id)kCVMetalTextureUsage:@(MTLTextureUsageShaderWrite)};
      if(CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,s.cache,buffer,(__bridge CFDictionaryRef)usage,
          format,kTileSize/(plane?2:1),kTileSize/(plane?2:1),plane,&views[plane])!=kCVReturnSuccess) {
        release();throw std::runtime_error("cannot map HEVC IOSurface planes for Metal");
      }
    }
    auto command=[s.queue commandBuffer];auto encoder=[command computeCommandEncoder];
    if(!command||!encoder) {release();throw std::runtime_error("cannot create Metal HEVC command");}
    [encoder setComputePipelineState:s.pipeline];[encoder setBuffer:s.input offset:0 atIndex:0];
    [encoder setBytes:&p length:sizeof(p) atIndex:1];
    [encoder setTexture:CVMetalTextureGetTexture(views[0]) atIndex:0];[encoder setTexture:CVMetalTextureGetTexture(views[1]) atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(256,256,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    [encoder endEncoding];[command commit];[command waitUntilCompleted];
    const bool failed=command.status==MTLCommandBufferStatusError;
    release();CVMetalTextureCacheFlush(s.cache,0);
    if(failed)throw std::runtime_error("Metal HEVC conversion failed");
    if(std::getenv("HYPERDR_METAL_AUDIT")) {
      auto reference=make_tile(depth);rgb_tile(grid,index,read,matrix,false,reference);
      CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
      unsigned changed=0,max=0;
      for(unsigned plane=0;plane<2;++plane) {
        const auto& ref=plane?reference.chroma:reference.luma;
        const auto* data=static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer,plane));
        const auto stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane);const unsigned bytes=depth==10?2:1;
        for(unsigned y=0;y<(plane?256:512);++y)for(unsigned x=0;x<512;++x) {
          auto a=unsigned(ref[(std::size_t(y)*512+x)*bytes]),b=unsigned(data[y*stride+x*bytes]);
          if(bytes==2) {a=(a|(unsigned(ref[(std::size_t(y)*512+x)*bytes+1])<<8))>>6;b=(b|(unsigned(data[y*stride+x*bytes+1])<<8))>>6;}
          const auto d=unsigned(std::abs(int(a)-int(b)));changed+=d!=0;max=std::max(max,d);
          if(d&&changed<5)std::fprintf(stderr,"METAL_DIFF plane=%u x=%u y=%u cpu=%u gpu=%u\n",plane,x,y,a,b);
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
      if(changed) {std::fprintf(stderr,"METAL_AUDIT changed=%u max=%u depth=%d matrix=%d\n",changed,max,depth,matrix);throw std::runtime_error("Metal source codes differ");}
    }
    check_cancelled();
  }
}
} // namespace hyperdr::codec::hevc

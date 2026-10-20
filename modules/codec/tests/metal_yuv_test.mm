#include "hevc/metal_yuv.hpp"
#include "hyperdr/image/transfer.hpp"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <iostream>
#include <stdexcept>
#include <cstring>
using namespace hyperdr::codec::hevc;
int main() try {
  if(!MTLCreateSystemDefaultDevice())return 77;
  MetalRgbTiles metal;
  for(int depth:{8,10})for(int matrix:{1,9})for(int transfer:{0,16,18}) {
    const auto grid=tile_grid(521,533);
    RgbRowReader read=[transfer](unsigned y,unsigned x,unsigned count,float* out) {
      for(unsigned i=0;i<count;++i) {
        const float u=float(x+i)/520.f,v=float(y)/532.f;
        std::array<float,3> rgb{u, v, .15f+u*v*3.f};
        if(transfer==16)for(auto& value:rgb)value=hyperdr::pq_oetf(value);
        if(transfer==18)rgb=hyperdr::hlg_encode(rgb);
        std::copy(rgb.begin(),rgb.end(),out+i*3);
      }
    };
    auto attributes=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferRef buffer{};
    if(CVPixelBufferCreate(kCFAllocatorDefault,512,512,depth==10?kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,(__bridge CFDictionaryRef)attributes,&buffer))throw std::runtime_error("buffer allocation");
    auto cpu=make_tile(depth);unsigned changed=0,max=0;
    for(std::size_t i=0;i<grid.count();++i) {
      rgb_tile(grid,i,read,matrix,false,cpu);metal.convert(grid,i,read,matrix,depth,buffer);
      CVPixelBufferLockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
      for(unsigned plane=0;plane<2;++plane) {
        const auto& ref=plane?cpu.chroma:cpu.luma;
        auto* data=static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer,plane));
        const auto stride=CVPixelBufferGetBytesPerRowOfPlane(buffer,plane);
        const unsigned bytes=depth==10?2:1;
        for(unsigned y=0;y<(plane?256:512);++y)for(unsigned x=0;x<512;++x) {
          unsigned a=ref[(std::size_t(y)*512+x)*bytes],b=data[y*stride+x*bytes];
          if(bytes==2){a=(a|(unsigned(ref[(std::size_t(y)*512+x)*bytes+1])<<8))>>6;b=(b|(unsigned(data[y*stride+x*bytes+1])<<8))>>6;}
          const auto d=unsigned(std::abs(int(a)-int(b)));if(d&&changed<6)std::cout<<"diff plane="<<plane<<" x="<<x<<" y="<<y<<" cpu="<<a<<" gpu="<<b<<'\n';
          changed+=d!=0;max=std::max(max,d);
        }
      }
      CVPixelBufferUnlockBaseAddress(buffer,kCVPixelBufferLock_ReadOnly);
    }
    CFRelease(buffer);std::cout<<"depth="<<depth<<" matrix="<<matrix<<" transfer="<<transfer<<" changed="<<changed<<" max="<<max<<'\n';
    if(max)throw std::runtime_error("Metal quantizer differs from CPU");
  }
  return 0;
} catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}

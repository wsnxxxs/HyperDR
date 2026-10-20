#pragma once
#include "hevc.hpp"
#include <CoreVideo/CoreVideo.h>
#include <memory>

namespace hyperdr::codec::hevc {
// Bounded experimental GPU converter. The caller supplies transfer-encoded
// RGB; Metal writes the encoder's IOSurface planes and completes before return.
class MetalRgbTiles {
 public:
  MetalRgbTiles();
  ~MetalRgbTiles();
  MetalRgbTiles(const MetalRgbTiles&)=delete;
  void convert(const TileGrid&,std::size_t,const RgbRowReader&,int matrix,
               int bit_depth,CVPixelBufferRef);
 private:
  struct State;
  std::unique_ptr<State> state_;
};
} // namespace hyperdr::codec::hevc

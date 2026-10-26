#pragma once
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include <algorithm>
#include <cmath>
#include <optional>

namespace hyperdr::codec {
// All checks operate on native pixels; no preview reduction or sparse mat sampling.
class VerificationPixels {
 public:
  VerificationResult result;
  std::optional<VerificationFrame> frame;
  std::optional<GainMapMetadata> metadata;
  VerificationPixels(unsigned width,unsigned height,std::optional<VerificationFrame> f,
                     std::optional<GainMapMetadata> m = {}) : frame(f),metadata(m) {
    result.width=width;result.height=height;
    if(frame && (frame->width!=width || frame->height!=height || !metadata))
      throw std::runtime_error("the framed package read back at a different size or without a gain map");
  }
  void row(unsigned x0,unsigned y,std::span<const float> base,std::span<const float> gain = {}) {
    check_cancelled();
    const unsigned channels=metadata ? gain_map_channel_count(*metadata):0;
    const unsigned width=base.size()/3;
    if(channels && gain.size()!=std::size_t(width)*channels)
      throw std::runtime_error("verification gain/base row mismatch");
    for(unsigned x=0;x<width;++x) {
      ++result.pixels;
      for(unsigned c=0;c<3;++c) {
        const float sdr=base[x*3+c];
        if(!std::isfinite(sdr))throw std::runtime_error("nonfinite decoded base sample");
        if(!channels)continue;
        const auto channel=gain_map_channel(*metadata,channels==1?0:c);
        const float code=gain[x*channels+(channels==1?0:c)];
        if(!std::isfinite(code) || code<0 || code>1)throw std::runtime_error("invalid decoded gain code");
        const float logGain=std::lerp(rational_value(channel.gain_min),rational_value(channel.gain_max),
                                     std::pow(code,1.f/rational_value(channel.gamma)));
        result.gainMinimum=std::min(result.gainMinimum,logGain);
        result.gainMaximum=std::max(result.gainMaximum,logGain);
        const float fraction=std::abs(rational_value(metadata->alternate_headroom)-rational_value(metadata->base_headroom))<1e-8f?0.f:1.f;
        const float hdr=std::max(0.f,(sdr+rational_value(channel.base_offset))*std::exp2(logGain*fraction)-rational_value(channel.alternate_offset));
        if(!std::isfinite(hdr))throw std::runtime_error("nonfinite reconstructed HDR sample");
        if(frame && outside(x0+x,y)) {
          const float difference=std::abs(hdr-sdr);
          if(difference>1e-5f*(1+std::abs(sdr)))
            throw std::runtime_error("the framed mat carries gain at "+std::to_string(x0+x)+","+std::to_string(y));
        }
      }
    }
  }
 private:
  bool outside(unsigned x,unsigned y) const {
    const auto& f=*frame;
    // Same one-coding-block exclusion as the previous whole-image E5 check.
    const auto left=f.x>8?f.x-8:0,top=f.y>8?f.y-8:0;
    return x<left || x>=std::min(f.width,f.x+f.photoWidth+8) ||
           y<top || y>=std::min(f.height,f.y+f.photoHeight+8);
  }
};
VerificationResult verify_jpeg_pixels(std::span<const std::uint8_t>,bool gain,std::optional<VerificationFrame>);
VerificationResult verify_heif_pixels(std::span<const std::uint8_t>,HdrEncoding,std::optional<VerificationFrame>);
VerificationResult verify_tiff_pixels(std::span<const std::uint8_t>);
VerificationResult verify_lossless_pixels(std::span<const std::uint8_t>,HdrEncoding);
} // namespace hyperdr::codec

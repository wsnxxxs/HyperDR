#pragma once
#include "cicp.hpp"
namespace hyperdr::codec {
// HEIF matrices produce continuous, possibly out-of-gamut encoded RGB.
// Preserve it through ICC/CICP; gamut mapping belongs to rendering.
class FloatRgbRowTransform {
 public:
  explicit FloatRgbRowTransform(const SourceColor& color)
      : primaries_(color.primaries), transfer_(color.transfer) {
    if (!color.icc.empty()) {
      const ProfileHandle source(cmsOpenProfileFromMem(color.icc.data(), color.icc.size()));
      if (!source || cmsGetColorSpace(source.get()) != cmsSigRgbData)
        throw std::runtime_error("embedded HEIF ICC profile is not readable RGB");
      const auto destination = linear_display_p3_profile();
      transform_.reset(cmsCreateTransform(source.get(), TYPE_RGB_FLT, destination.get(),
                                          TYPE_RGB_FLT, INTENT_RELATIVE_COLORIMETRIC,
                                          cmsFLAGS_NOOPTIMIZE | cmsFLAGS_NOCACHE));
      if (!transform_) throw std::runtime_error("cannot build HEIF float ICC transform");
    } else {
      (void)encoded_to_linear_p3(0, 0, 0, primaries_, transfer_);
      // Continuous interpolation, not code quantization. The exact transfer
      // handles excursions; the LUT avoids per-channel pow on 61MP HLG inputs.
      table_.resize(65537);
      for (unsigned i = 0; i < table_.size(); ++i) table_[i] = exact(float(i) / 65536);
    }
  }
  void convert(const float* source, float* target, unsigned width) const {
    if (transform_) {
      cmsDoTransform(transform_.get(), source, target, width);
      return;
    }
    for (unsigned x = 0; x < width; ++x) {
      const auto i = std::size_t(x) * 3;
      std::array<float, 3> linear{decode(source[i]), decode(source[i + 1]), decode(source[i + 2])};
      if (transfer_ == kCicpTransferHlg)
        linear = hlg_ootf(linear, cicp_luminance_weights(primaries_));
      const auto p3 =
          encoded_to_linear_p3(linear[0], linear[1], linear[2], primaries_, kCicpTransferLinear);
      std::copy(p3.begin(), p3.end(), target + i);
    }
  }

 private:
  float exact(float v) const {
    return transfer_ == kCicpTransferHlg
               ? hlg_inverse_oetf_scene(v)
               : std::copysign(decode_transfer(std::abs(v), transfer_), v);
  }
  float decode(float v) const {
    if (!(v >= 0 && v < 1)) return exact(v);
    const float position = v * 65536;
    const auto i = static_cast<unsigned>(position);
    return table_[i] + (table_[i + 1] - table_[i]) * (position - i);
  }
  int primaries_, transfer_;
  TransformHandle transform_;
  std::vector<float> table_;
};
}  // namespace hyperdr::codec

#include "hyperdr/container/heif_writer.hpp"
#include "internal/boxes.hpp"
#include "internal/hevc_parameters.hpp"
#include <array>
#include <limits>

namespace hyperdr {
HevcConfiguration make_hevc_configuration(std::span<const std::uint8_t> vps,
    std::span<const std::uint8_t> sps, std::span<const std::uint8_t> pps) {
  const std::array sets{vps, sps, pps};
  for (std::size_t i = 0; i < sets.size(); ++i) {
    if (sets[i].size() > 65535 || container::nal_type(sets[i]) != 32 + i ||
        (sets[i][0] & 1) || (sets[i][1] >> 3) || (sets[i][1] & 7) != 1)
      throw std::invalid_argument("invalid single-layer HEVC parameter set");
  }
  const auto vps_data=container::rbsp(vps),sps_data=container::rbsp(sps),pps_data=container::rbsp(pps);
  container::HevcBits vps_bits(vps_data),sps_bits(sps_data),pps_bits(pps_data);
  const auto vps_syntax=container::validate_vps(vps_bits);
  const auto parsed=container::validate_sps(sps_bits,vps_syntax);
  container::validate_pps(pps_bits,parsed);
  const auto& profile=parsed.profile;
  const auto chroma=parsed.chroma,depth_y=parsed.depth,depth_c=parsed.depth;
  const auto layers=parsed.layers,nested=parsed.nested;
  HevcConfiguration result;
  result.width = parsed.width;
  result.height = parsed.height;
  result.bit_depth = 8 + depth_y;
  result.chroma_format = chroma;
  auto& out = result.record;
  out.push_back(1);
  out.insert(out.end(), profile.begin(), profile.end());
  container::put16(out, 0xF000); // min_spatial_segmentation_idc unspecified
  out.push_back(0xFC);          // parallelismType unspecified
  out.push_back(static_cast<std::uint8_t>(0xFC | chroma));
  out.push_back(static_cast<std::uint8_t>(0xF8 | depth_y));
  out.push_back(static_cast<std::uint8_t>(0xF8 | depth_c));
  container::put16(out, 0);     // avgFrameRate unspecified for still images
  out.push_back(static_cast<std::uint8_t>(((layers + 1) << 3) | (nested << 2) | 3));
  out.push_back(3);
  for (std::size_t i = 0; i < sets.size(); ++i) {
    out.push_back(static_cast<std::uint8_t>(0x80 | (32 + i)));
    container::put16(out, 1);
    container::put16(out, static_cast<std::uint16_t>(sets[i].size()));
    out.insert(out.end(), sets[i].begin(), sets[i].end());
  }
  return result;
}
} // namespace hyperdr

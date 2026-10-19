#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "internal/boxes.hpp"
#include "internal/hevc_parameters.hpp"
#include <array>
#include <limits>

namespace hyperdr {
HevcConfiguration make_hevc_configuration(std::span<const std::uint8_t> vps,
                                          std::span<const std::uint8_t> sps,
                                          std::span<const std::uint8_t> pps) {
  const std::array sets{vps, sps, pps};
  for (std::size_t i = 0; i < sets.size(); ++i) {
    if (sets[i].size() > 65535 || container::nal_type(sets[i]) != 32 + i ||
        (sets[i][0] & 1) || (sets[i][1] >> 3) || (sets[i][1] & 7) != 1)
      throw std::invalid_argument("invalid single-layer HEVC parameter set");
  }
  const auto vps_data = container::rbsp(vps), sps_data = container::rbsp(sps),
             pps_data = container::rbsp(pps);
  container::HevcBits vps_bits(vps_data), sps_bits(sps_data),
      pps_bits(pps_data);
  const auto vps_syntax = container::validate_vps(vps_bits);
  const auto parsed = container::validate_sps(sps_bits, vps_syntax);
  container::validate_pps(pps_bits, parsed);
  const auto &profile = parsed.profile;
  const auto chroma = parsed.chroma, depth_y = parsed.depth,
             depth_c = parsed.depth;
  const auto layers = parsed.layers, nested = parsed.nested;
  HevcConfiguration result;
  result.width = parsed.width;
  result.height = parsed.height;
  result.bit_depth = 8 + depth_y;
  result.chroma_format = chroma;
  auto &out = result.record;
  out.push_back(1);
  out.insert(out.end(), profile.begin(), profile.end());
  container::put16(out, 0xF000); // min_spatial_segmentation_idc unspecified
  out.push_back(0xFC);           // parallelismType unspecified
  out.push_back(static_cast<std::uint8_t>(0xFC | chroma));
  out.push_back(static_cast<std::uint8_t>(0xF8 | depth_y));
  out.push_back(static_cast<std::uint8_t>(0xF8 | depth_c));
  container::put16(out, 0); // avgFrameRate unspecified for still images
  out.push_back(
      static_cast<std::uint8_t>(((layers + 1) << 3) | (nested << 2) | 3));
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

// Reader-side hvcC accepts RExt and monochrome as well as the writer's bounded
// Main/Main10 syntax. It does not loosen make_hevc_configuration's contract.
#include "hyperdr/container/heif_reader.hpp"
#include "internal/bmff.hpp"
#include <cstring>
namespace hyperdr {
namespace {
void read_profile(container::HevcBits &b, unsigned layers) {
  b.skip(96);
  std::array<bool, 7> p{}, l{};
  for (unsigned i = 0; i < layers; ++i) {
    p[i] = b.take(1);
    l[i] = b.take(1);
  }
  if (layers)
    b.skip(2 * (8 - layers));
  for (unsigned i = 0; i < layers; ++i) {
    if (p[i])
      b.skip(88);
    if (l[i])
      b.skip(8);
  }
}
void read_sps(HvcConfig &c, std::span<const std::uint8_t> nal) {
  using namespace container;
  const auto data = rbsp(nal);
  HevcBits b(data);
  b.skip(4);
  const auto layers = b.take(3);
  hevc_require(layers <= 6);
  b.skip(1);
  read_profile(b, layers);
  (void)limited_ue(b, 15);
  const auto chroma = limited_ue(b, 3);
  if (chroma == 3 && b.take(1))
    throw HeifReadError("separate colour planes are unsupported",
                        "hevc_separate_planes");
  const auto width = limited_ue(b, 131072), height = limited_ue(b, 131072);
  hevc_require(width && height);
  std::uint64_t crop_x = 0, crop_y = 0;
  if (b.take(1)) {
    auto l = b.ue(), r = b.ue(), t = b.ue(), bottom = b.ue();
    crop_x = (std::uint64_t(l) + r) * (chroma == 1 || chroma == 2 ? 2 : 1);
    crop_y = (std::uint64_t(t) + bottom) * (chroma == 1 ? 2 : 1);
  }
  hevc_require(crop_x < width && crop_y < height);
  c.width = width - static_cast<unsigned>(crop_x);
  c.height = height - static_cast<unsigned>(crop_y);
  const auto depth = limited_ue(b, 8);
  hevc_require(b.ue() == depth);
  hevc_require(c.chroma_format == chroma && c.bit_depth == depth + 8);
  const auto poc = limited_ue(b, 12) + 4;
  const auto dpb = ordering(b, layers);
  auto min_cb = limited_ue(b, 3) + 3;
  auto cb_difference = limited_ue(b, 3);
  auto ctb = min_cb + cb_difference;
  hevc_require(ctb <= 6);
  (void)limited_ue(b, 3);
  (void)limited_ue(b, 3);
  (void)limited_ue(b, 6);
  (void)limited_ue(b, 6);
  if (b.take(1) && b.take(1))
    scaling_list(b);
  b.skip(2);
  if (b.take(1)) {
    b.skip(8);
    (void)limited_ue(b, 3);
    (void)limited_ue(b, 3);
    b.skip(1);
  }
  short_term_sets(b, dpb);
  if (b.take(1))
    for (unsigned i = 0, n = limited_ue(b, 32); i < n; ++i)
      b.skip(poc + 1);
  b.skip(2);
  if (!b.take(1))
    return;
  if (b.take(1)) {
    if (b.take(8) == 255)
      b.skip(32);
  }
  if (b.take(1))
    b.skip(1);
  if (b.take(1)) {
    b.skip(3);
    HeifNclx color{2, 2, 2, b.take(1) != 0};
    if (b.take(1)) {
      color.primaries = b.take(8);
      color.transfer = b.take(8);
      color.matrix = b.take(8);
    }
    c.vui_color = color;
  }
  if (b.take(1)) {
    c.chroma_location_top = limited_ue(b, 5);
    c.chroma_location_bottom = limited_ue(b, 5);
  }
  // The remaining VUI, HRD and RExt flags are not needed to decode a still.
  // Their complete syntax is validated by VideoToolbox, not guessed here.
}
} // namespace
HvcConfig parse_hevc_configuration(std::span<const std::uint8_t> bytes) {
  using namespace container;
  try {
    require_heif(bytes.size() >= 23, "truncated hvcC");
    BmffCursor b(bytes);
    require_heif(b.integer(1) == 1, "unsupported hvcC version");
    HvcConfig out;
    out.profile = static_cast<unsigned>(b.integer(1)) & 31;
    b.take(11);
    require_heif((b.integer(2) & 0xF000) == 0xF000,
                 "invalid hvcC reserved bits");
    require_heif((b.integer(1) & 0xFC) == 0xFC, "invalid hvcC reserved bits");
    auto chroma = b.integer(1), luma = b.integer(1),
         chroma_depth = b.integer(1);
    require_heif((chroma & 0xFC) == 0xFC && (luma & 0xF8) == 0xF8 &&
                     (chroma_depth & 0xF8) == 0xF8,
                 "invalid hvcC reserved bits");
    out.chroma_format = chroma & 3;
    out.bit_depth = 8 + (luma & 7);
    require_heif((chroma_depth & 7) == (luma & 7),
                 "HEVC component depths differ");
    b.take(2);
    out.length_size = (static_cast<unsigned>(b.integer(1)) & 3) + 1;
    require_heif(out.length_size != 3, "unsupported hvcC NAL length size");
    auto arrays = b.integer(1);
    require_heif(arrays <= heif_limits::nal_count, "too many hvcC NAL arrays");
    bool vps = false, sps = false, pps = false;
    std::size_t count = 0;
    for (std::uint64_t i = 0; i < arrays; ++i) {
      auto header = b.integer(1);

      auto type = header & 63, n = b.integer(2);
      require_heif(n <= heif_limits::nal_count - count,
                   "too many hvcC NAL units");
      count += static_cast<std::size_t>(n);
      for (std::uint64_t j = 0; j < n; ++j) {
        auto size = b.integer(2);
        require_heif(size >= 3 && size <= heif_limits::nal_bytes,
                     "invalid hvcC NAL size");
        auto nal = b.take(static_cast<std::size_t>(size));
        require_heif(nal_type(nal) == type && !(nal[0] & 1) && !(nal[1] >> 3),
                     "invalid hvcC single-layer NAL");
        if (type == 32)
          vps = true;
        if (type == 33) {
          require_heif(!sps, "multiple HEVC SPS are unsupported");
          sps = true;
          read_sps(out, nal);
        }
        if (type == 34)
          pps = true;
        out.parameter_sets.emplace_back(nal.begin(), nal.end());
      }
    }
    b.end();
    require_heif(vps && sps && pps, "hvcC lacks VPS/SPS/PPS");
    out.record.assign(bytes.begin(), bytes.end());
    return out;
  } catch (const HeifReadError &) {
    throw;
  } catch (const std::exception &e) {
    throw HeifReadError(e.what());
  }
}
void validate_hevc_sample(std::span<const std::uint8_t> bytes,
                          const HvcConfig &config) {
  using namespace container;
  require_heif(!bytes.empty() && bytes.size() <= heif_limits::sample_bytes,
               "invalid HEVC sample size");
  require_heif(config.length_size == 1 || config.length_size == 2 ||
                   config.length_size == 4,
               "invalid HEVC NAL length size");
  BmffCursor b(bytes);
  bool irap = false;
  std::size_t vcl = 0, pictures = 0, nal_count = 0;
  while (b.remaining()) {
    if ((nal_count++ & 1023) == 0) check_cancelled();
    auto n = b.integer(config.length_size);
    require_heif(n >= 2 && n <= b.remaining(),
                 "HEVC NAL length overruns the sample");
    auto nal = b.take(static_cast<std::size_t>(n));
    require_heif(!(nal[0] & 0x80) && !(nal[0] & 1) && !(nal[1] >> 3) &&
                     (nal[1] & 7),
                 "invalid HEVC single-layer NAL header");
    auto type = (nal[0] >> 1) & 63;
    if (type < 32) {
      require_heif(nal.size() >= 3, "truncated HEVC slice header");
      pictures += (nal[2] & 0x80) != 0;
      ++vcl;
      irap |= type >= 16 && type <= 21;
    }
    if (type >= 32 && type <= 34) {
      bool same = false;
      for (const auto &set : config.parameter_sets)
        if (set.size() == nal.size() &&
            std::equal(set.begin(), set.end(), nal.begin()))
          same = true;
      if (!same)
        throw HeifReadError("HEVC sample changes in-band parameter sets",
                            "hevc_parameter_change");
    }
  }
  require_heif(vcl && irap, "HEVC sample lacks an IRAP picture");
  require_heif(pictures == 1, "HEVC sample must contain exactly one picture");
}
} // namespace hyperdr

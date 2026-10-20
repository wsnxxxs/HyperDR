#pragma once
#include "hyperdr/look/options.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/image/frame.hpp"
#include "hyperdr/image/color.hpp"
#include <array>
#include <optional>
namespace hyperdr {
struct RenderStats {
  float exposure_ev{0.0F};
  std::optional<float> ev100;
  float target_middle_gray{0.18F};

  float headroom_stops{0.0F};
  float headroom_linear{1.0F};
  float rendered_peak{1.0F};
  float headroom_utilization{0.0F};

  float gain_min_stops{0.0F};
  float gain_max_stops{0.0F};
  float gain_gamma{1.0F};
  std::array<float, 8> gain_percentiles{};
  float gain_fraction_gt_0_5{0.0F};
  float gain_fraction_gt_1_0{0.0F};
  float gain_fraction_gt_2_0{0.0F};
  float gain_clipped_fraction{0.0F};

  float local_weight_mean{1.0F};
  float local_weight_p95{1.0F};
  float below_knee_relative_difference_max{0.0F};
  // Input-domain fraction of sufficiently bright, linear Display P3 pixels
  // whose chromaticity lies outside Rec.709. It is measured before exposure
  // or look rendering, so it isolates the decoded wide-gamut input from
  // contrast, vibrance, and pop.
  float wide_gamut_fraction{0.0F};
  std::uint64_t wide_gamut_pixels{0};
  std::uint64_t wide_gamut_eligible_pixels{0};
  float wide_gamut_luminance_threshold{0.02F};
  // Apple-compatible monochrome packaging had to derive a new SDR colour.
  bool adaptive_chroma_loss{false};
};

struct PhotoRenditions {
  FloatImage sdr;
  FloatImage hdr;
  // A framed gain-map export owns only the SDR canvas and the HDR photograph.
  // Outside this rectangle the alternate is exactly the SDR canvas pixel.
  std::optional<FrameRect> hdr_photo;
  [[nodiscard]] const float* hdr_pixel(std::uint32_t x, std::uint32_t y) const noexcept {
    if (hdr_photo) {
      const auto& r = *hdr_photo;
      if (x < r.x || y < r.y || x - r.x >= r.width || y - r.y >= r.height)
        return sdr.pixels.data() + (static_cast<std::size_t>(y) * sdr.width + x) * 3;
      return hdr.pixels.data() + (static_cast<std::size_t>(y - r.y) * hdr.width + x - r.x) * 3;
    }
    return hdr.pixels.data() + (static_cast<std::size_t>(y) * hdr.width + x) * 3;
  }
  // The HDR rendition is the photograph itself rather than an expansion the
  // renderer invented, so a gain map must decode back to it pixel for pixel.
  // Set for a display-referred HDR input; the packager derives the base from
  // these HDR pixels and the quantized gain. `sdr` supplies each pixel's tone-mapped
  // luminance. Cleared by grading that gives the SDR
  // rendition a colour of its own.
  bool hdr_is_source{false};
  bool dual_rendition{false};
  std::uint32_t authored_gain_channels{1};
  // A model or external gain grid: the stored gain map keeps the grid's
  // channel count instead of one chosen from the codes' content.
  bool fixed_gain_channels{false};
  AuthoredGainMap authored_gain_map{};
  RenderStats stats;
  bool clamp_srgb{false};
  ColorGamut hdr_gamut{ColorGamut::kDisplayP3};
  // Selection made before creative grading; reused after gain quantization.
  BytePlane below_knee;
};
void fit_sdr_to_srgb(FloatImage& image);
}

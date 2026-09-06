#pragma once
#include "hyperdr/look/options.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/image/image.hpp"
#include <array>
#include <optional>
#include <span>

namespace hyperdr {
struct RenderOptions {
  // Keep the rendered base and its gain-map reconstruction inside sRGB
  // chromaticity while retaining HDR luminance headroom.
  bool clamp_srgb{false};
  bool auto_exposure{true};
  float exposure_ev{0.0F};
  // Creative offset applied after automatic or manual exposure selection.
  // Unlike HDR gain controls, this moves the SDR base and HDR rendition together.
  //
  // Zero, which is what the documentation has always said and what the panel
  // has always sent explicitly. It defaulted to +1 EV here, so a bare
  // `HyperDR convert` brightened every file by a stop that nothing in the run
  // reported as a decision -- least visibly on a display-referred input, where
  // it also pushed diffuse white into the top codes of the SDR base.
  float exposure_bias_ev{0.0F};
  bool auto_headroom{true};
  float headroom_stops{3.0F};
  float gain_strength{1.0F};
  // Optional cap used only when an external/model gain map is replayed. It is
  // deliberately separate from `headroom_stops`: the model's development
  // recipe must remain intact so its SDR base stays reproducible, while the
  // selected output format may still impose a lower display ceiling.
  float output_headroom_limit_stops{-1.0F};
  LookOptions look{};
};

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
};

// Owned by an interactive caller, invalidated when source, render target or any
// option except gain strength changes. Ordinary exports do not allocate caches.
struct BaseRenderCache {
  FloatImage base;
  std::vector<float> luminance;
};
struct GainMapPreparation {
  bool ready{false};
  std::uint32_t width{}, height{};
  float exposure_ev{}, requested_stops{}, weight_mean{1}, weight_p95{1};
  std::vector<float> stops, local_average;
  BaseRenderCache base;
  RenderStats base_stats;
};


// Float renditions are the render contract. SDR-only has an empty hdr buffer.
// No container, encoded gain codes or ISO metadata belong in this layer.
enum class RenderTarget { Sdr, Hdr };
RenderOptions render_options_for_target(RenderOptions options, RenderTarget target);
struct PhotoRenditions {
  FloatImage sdr;
  FloatImage hdr;
  // Original spatial log2 gain, before interpolation/quantization.
  // Cleared by grading that changes the SDR/HDR relation.
  FloatImage gain_stops;
  RenderStats stats;
  bool clamp_srgb{false};
  // Selection made before creative grading; reused after gain quantization.
  std::vector<std::uint8_t> below_knee;
};
void measure_rendition_stats(RenderStats& stats, const FloatImage& sdr,
    const FloatImage& hdr, std::span<const std::uint8_t> below_knee = {});
// Final SDR output gamut mapping, after creative colour processing.
void fit_sdr_to_srgb(FloatImage& image);
void validate_render_options(const RenderOptions& options);
float photographic_exposure_ev(const FloatImage& source,
    const RenderOptions& options, const CaptureMetadata& capture = {});
void prepare_photographic_render(const FloatImage& source,
    const RenderOptions& options, const CaptureMetadata& capture,
    const PhotographicAnalysis* analysis, GainMapPreparation& prepared);
std::array<float, 3> render_common_chroma(float r, float g, float b,
    float source_y, float sdr_y, float hdr_y, float peak, const LookOptions& look);
PhotoRenditions render_renditions(const FloatImage& source,
    const RenderOptions& options, const CaptureMetadata& capture,
    const InputDescription& input, RenderTarget target,
    const PhotographicAnalysis* analysis = nullptr,
    GainMapPreparation* preparation = nullptr);
}  // namespace hyperdr

#pragma once

// What the photographer asked for, and what the camera recorded.
//
// These controls describe rendering intent only. Nothing here knows about gain
// maps, containers, or codecs, which is what lets the tone curve, the exposure
// estimator and the headroom selector be tested without an encoder present.

#include <optional>
#include <string_view>

namespace hyperdr {

// The rendering mode is deliberately separate from the ISO gain-map metadata.
// `kNeutral` preserves the legacy renderer for reproducible comparison and
// rollback, while `kPhotographic` uses the perceptual HDR pipeline.
enum class LookMode {
  kNeutral,
  kPhotographic,
};

// The neutral renderer's fixed contract, named once.
//
// Neutral compresses highlights with a hard-coded knee and clamps its own
// headroom, and those two numbers used to live only inside the renderer. The
// curve export therefore described the photographic curve while the renderer
// used this one, and `--headroom 4` was accepted, reported, and then silently
// rendered at 3 -- so the panel's HDR preview, built from the exported curve,
// could not match the file it was previewing. Everything that has an opinion
// about the neutral look now reads these.
inline constexpr float kNeutralKnee = 0.75F;
inline constexpr float kNeutralHeadroomStops = 3.0F;

// The strongest expansion the given look can represent, before any content
// dependent selection narrows it.
[[nodiscard]] constexpr float look_headroom_ceiling_stops(LookMode mode,
                                                          float configured) {
  return mode == LookMode::kNeutral
             ? (configured < kNeutralHeadroomStops ? configured
                                                   : kNeutralHeadroomStops)
             : configured;
}

[[nodiscard]] const char* look_mode_name(LookMode mode);
// Returns nullopt rather than a default, so an unrecognised name is the
// caller's error to report rather than a silent fallback to photographic.
[[nodiscard]] std::optional<LookMode> look_mode_from_name(std::string_view name);

// These values are intentionally optional: a missing EXIF field must not be
// silently replaced with a plausible-looking capture setting.
struct CaptureMetadata {
  std::optional<float> iso;
  std::optional<float> exposure_time_seconds;
  std::optional<float> aperture_f_number;
};

struct LookOptions {
  LookMode mode{LookMode::kPhotographic};
  float contrast{1.08F};
  float vibrance{0.12F};
  float headroom_max_stops{4.0F};
  // EDR "pop": 0 keeps the restrained photographic default; 1 pushes the
  // HDR-only strength (diffuse gain floor, headroom bias, and coloured-
  // highlight retention). It only affects rendering above the shoulder, so
  // the SDR base and below-shoulder invariant are unchanged.
  float pop{0.0F};

  // Tone-region controls. `shoulder_start` is the linear SDR-output level where
  // HDR-only expansion begins. `diffuse_gain_floor` controls how much of the
  // qualifying bright region participates before local/specular weighting.
  // Shadows remain excluded by the shoulder invariant and noise guard.
  float toe_end{0.08F};
  float toe_output_ratio{2.0F / 3.0F};
  // Begin the HDR-only transition in the upper-middle display range. The old
  // 0.72 knee confined useful gain to a tiny fraction of real photographs.
  float shoulder_start{0.48F};
  float positive_exposure_limit_ev{1.5F};
  float diffuse_gain_floor{0.35F};
};

// Rejects out-of-range creative controls before anything is decoded or
// allocated. Neutral mode ignores the photographic tuning controls, so their
// ranges are only enforced for the look that reads them; the structural
// invariants the tone curve needs are checked for both.
void validate_look_options(const LookOptions& options);

}  // namespace hyperdr

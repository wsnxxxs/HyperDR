#pragma once

#include <array>
#include <cstdint>
#include <memory>

// What the photographer asked for, and what the camera recorded.
//
// These controls describe rendering intent only. Nothing here knows about gain
// maps, containers, or codecs, which is what lets the tone curve, the exposure
// estimator and the headroom selector be tested without an encoder present.

#include <optional>
#include <string_view>

namespace hyperdr {

struct FloatImage;

// Which domain a decoded image's float samples live in.
//
// The renderer cannot decide what its tone curve means without this. It used to
// be inferred from the file name -- ".arw" or ".dng" meant scene-referred and
// everything else meant display-referred -- which is wrong in both directions:
// an Ultra HDR JPEG whose gain map failed to decode is a display-referred SDR
// image while its extension still says ".jpg", and a PQ HEIC and an sRGB HEIC
// share an extension while living two very different distances above diffuse
// white. It is a property of what the decoder produced, so the decoder sets it.
enum class InputDomain {
  // Sensor-linear and unbounded, with no rendering intent applied yet. 1.0 is
  // a white-balance normalisation artefact rather than diffuse white, which is
  // why this is the only domain that gets automatic photographic exposure.
  kSceneReferred,
  // A finished SDR rendition: 1.0 is diffuse white and also the ceiling.
  kDisplayReferredSdr,
  // A finished HDR rendition: 1.0 is diffuse white and everything above it is
  // real highlight detail, up to the input's declared headroom.
  kDisplayReferredHdr,
  // A finished SDR base and its authored HDR alternate are both available.
  kDualRendition,
  // Report-only value used when a file was skipped or failed before decoding.
  // It must never be passed to a renderer as an InputDescription.
  kUnknown,
};

[[nodiscard]] const char* input_domain_name(InputDomain domain);
// Returns nullopt for an unrecognised name rather than guessing: picking the
// wrong domain silently re-develops a finished photograph.
[[nodiscard]] std::optional<InputDomain> input_domain_from_name(
    std::string_view name);

// What the decoder produced, as opposed to what the user asked for. Neither
// field is a setting, which is why they travel beside GainMapOptions rather
// than inside it: they are facts about the file, already covered by the input
// hash, and must not enter the settings fingerprint.
struct AuthoredGainMap {
  std::array<float, 3> base_offset{};
  std::array<float, 3> alternate_offset{};
  // Linear multiples of reference white, converted to stops by the renderer.
  float base_headroom{1.0F};
  float alternate_headroom{1.0F};
  std::uint32_t channels{1};
};

struct InputDescription {
  InputDomain domain{InputDomain::kSceneReferred};
  // How far above diffuse white the input's *encoding* can carry detail, as a
  // linear multiple. Read for single HDR and dual-rendition inputs.
  float headroom{1.0F};
  // Optional MaxCLL in cd/m². This bounds tone mapping, not transfer decoding;
  // a PQ image with a 203-nit peak is still an already rendered HDR input.
  std::optional<float> content_peak_nits;
  const FloatImage* authored_sdr{nullptr};
  AuthoredGainMap gain_map{};
};

// Range to map after applying any content-light metadata. Unknown content
// retains the encoding's range; unit content headroom requires no HDR split.
[[nodiscard]] float rendering_headroom(const InputDescription& input);

// Rejects a description whose headroom contradicts its domain before any
// renderer divides by it.
void validate_input_description(const InputDescription& input);

// These values are intentionally optional: a missing EXIF field must not be
// silently replaced with a plausible-looking capture setting.
//
// The last three were added for the research gain-level model rather than for
// the renderer, and are carried here because every decoder already builds this
// one structure: a capture setting reachable from only some input formats would
// make the same photograph a different model input depending on its container.
struct CaptureMetadata {
  std::optional<float> iso;
  std::optional<float> exposure_time_seconds;
  std::optional<float> aperture_f_number;
  std::optional<float> exposure_bias_ev;
  std::optional<float> focal_length_mm;
  std::optional<float> focal_length_35mm;
};

} // namespace hyperdr

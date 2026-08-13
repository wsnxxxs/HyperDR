#pragma once

// Rendering an input that is already a finished photograph.
//
// The photographic renderer in photographic.cpp is scene-referred: it reads
// sensor-linear values whose 1.0 means nothing in particular, chooses an
// exposure from the scene's log average, and lands the result on a toe/linear/
// shoulder curve. Handing it a JPEG or a PQ HEIC re-develops a picture that was
// already developed -- an SDR input came back with its shadows a stop down and
// diffuse white at 0.83, and an HDR input had every value above roughly twice
// diffuse white flattened into the top code of the base, because that curve's
// shoulder asymptotes to 1.0 within about two stops.
//
// These two renderers are what a display-referred input gets instead. Both are
// built on one shoulder, `display_shoulder_log2`, applied in the log domain so
// that its knee is C1 and its reach is set by the ceiling rather than by how
// far the input happens to extend.

#include "hyperdr/gainmap/types.hpp"

namespace hyperdr {

// The shared shoulder, in log2 space throughout.
//
//   u <= knee:  v = u                       (identity, exactly)
//   u >  knee:  v = ceiling - span * exp(-(u - knee) / span),  span = ceiling - knee
//
// Identity below the knee, slope exactly 1 at the knee, monotonic, and
// asymptotic to `ceiling` from below without ever reaching it. `ceiling` is the
// only difference between the SDR base and the HDR rendition, which is what
// makes the two identical below the knee by construction rather than by
// convention -- the same guarantee the photographic curve gives, and the reason
// the gain map is zero there.
//
// Because it only approaches its ceiling, callers must not pass the value they
// want the input's peak to *land on*: they solve for the ceiling that puts it
// there. Passing the target directly rendered a 1.06-stop input at 0.42 stops
// and, since the ISO metadata declares the gain interval as the alternate
// headroom, shrank the declared range on every re-export.
//
// Working in log2 rather than linear is what keeps a large input headroom
// usable: a linear-domain shoulder spends nearly all of its output range on the
// first two stops, so a PQ input's 5.6 stops arrive at the base indistinguishable
// from each other. Requires `ceiling > knee`.
[[nodiscard]] float display_shoulder_log2(float u, float knee, float ceiling);

// A finished SDR rendition: the base is the input, and the gain map is zero.
//
// Exposure is honoured -- a manual --exposure and --exposure-bias both scale
// the image -- but automatic exposure is not, because a scene statistic taken
// from an already-graded picture would re-expose someone else's decision. When
// the scale pushes the image above 1.0 the excess is rolled off by the shared
// shoulder rather than clipped, so brightening posterises nothing; the gain map
// stays zero either way. An SDR input never gains highlight range it did not
// arrive with.
[[nodiscard]] GainMapResult make_display_referred_sdr_result(
    const FloatImage& linear_p3, const GainMapOptions& options);

// A finished HDR rendition, split into an SDR base and the gain map that
// restores it.
//
// `input_headroom` is the linear multiple of diffuse white the input's own
// container declared, not a percentile of its pixels. The output headroom is
// that value capped by the caller's target and by `gain_strength`, so a 5.6-stop
// PQ input converted to a 3-stop Adaptive HEIC is attenuated deliberately
// instead of being clipped by the encoder.
//
// The split follows the photographic renderer's: the base is the SDR shoulder
// applied per pixel, and the grid carries the cell-mean difference between the
// two ceilings. Deriving the base the other way round -- `hdr / 2^gain` -- would
// reconstruct more exactly, but a low-frequency grid that has to cover a
// specular also covers its dark surroundings, and the shadows next to every
// highlight would be crushed in the one image SDR viewers actually see.
[[nodiscard]] GainMapResult make_display_referred_hdr_gain_map(
    const FloatImage& linear_p3, const GainMapOptions& options,
    float input_headroom);

}  // namespace hyperdr

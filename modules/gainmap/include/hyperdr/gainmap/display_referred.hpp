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
// The SDR creative-expansion renderer remains here. Finished HDR photographs
// are split from full-resolution renditions by gain_map_from_renditions.
// Its shoulder helper is shared by the display-referred SDR renderer.

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

// A finished SDR rendition, expanded into a selectable HDR alternate.
//
// Exposure is honoured -- a manual --exposure and --exposure-bias both scale
// the image -- but automatic exposure is not, because a scene statistic taken
// from an already-graded picture would re-expose someone else's decision. The
// SDR input has no measured highlights above diffuse white, so the renderer
// pins exposure at the display-referred value and uses the requested range as
// a creative expansion budget. This makes the panel's HDR strength/range
// controls meaningful for ordinary JPEG/PNG photographs without claiming that
// the source file carried HDR.
[[nodiscard]] GainMapResult make_display_referred_sdr_result(
    const FloatImage& linear_p3, const GainMapOptions& options,
    const CaptureMetadata& capture = {}, GainMapPreparation* preparation = nullptr);

}  // namespace hyperdr

#pragma once

// The ordinary-EXIF level estimator, as a static tree walk.
//
// The research model 2 adds a single signed log2 scalar to a mean-removed
// spatial prediction. That scalar comes from a fitted
// ``SimpleImputer(median) + HistGradientBoostingRegressor`` pipeline, whose
// numbers are exported into ``research_exif_level_data.inc``. Walking the
// flattened trees here is deliberate: the alternative is a Python, sklearn or
// second heavyweight runtime inside the packaged application, and none of those
// belongs in an image converter.
//
// The fitted object remains the authority. The values in the generated header
// were read out of it, and the research reference runner replays this fold's
// recorded predictions through this same traversal, so "the C++ agrees with
// sklearn" is a checked statement rather than an assumption about how
// HistGradientBoosting works.

#include <array>
#include <cstddef>

namespace hyperdr {

//: The six ordinary capture parameters, in the order the training pipeline
//: builds them: log2 ISO, log2 exposure seconds, f-number, exposure bias in EV,
//: focal length and 35 mm-equivalent focal length.
inline constexpr std::size_t kCaptureParameterCount = 6;

//: The scalar model 2 adds to the mean-removed spatial prediction, in stops.
//:
//: `present` is per field and is not optional: a field that was not recorded is
//: replaced by the fitted median, exactly as the training pipeline's imputer
//: did. Passing a zero in `features` with `present[index] == false` therefore
//: means "median", while `present[index] == true` with a zero means the camera
//: recorded a zero -- which for the exposure bias is the ordinary value.
[[nodiscard]] double research_exif_level(
    const std::array<double, kCaptureParameterCount>& features,
    const std::array<bool, kCaptureParameterCount>& present);

}  // namespace hyperdr

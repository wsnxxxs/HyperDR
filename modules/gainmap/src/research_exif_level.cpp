#include "hyperdr/gainmap/research_exif_level.hpp"

#include "research_exif_level_data.inc"

#include <cmath>
#include <cstddef>
#include <limits>

namespace hyperdr {

double research_exif_level(
    const std::array<double, kCaptureParameterCount>& features,
    const std::array<bool, kCaptureParameterCount>& present) {
  static_assert(research_exif_data::kFieldCount == kCaptureParameterCount,
                "the exported estimator and the request contract disagree about "
                "how many capture parameters there are");

  // The imputer runs first and only on the fields that are absent: a recorded
  // value is never replaced, so a complete capture and an imputed one cannot be
  // confused even though both produce six finite numbers.
  std::array<double, kCaptureParameterCount> values{};
  for (std::size_t index = 0; index < kCaptureParameterCount; ++index) {
    const bool usable =
        present[index] && std::isfinite(features[index]);
    values[index] = usable ? features[index]
                           : research_exif_data::kImputerMedians[index];
  }

  // HistGradientBoosting predicts the baseline plus the sum of the trees'
  // leaves. Each leaf already carries the learning rate, so it is not applied
  // again here; that was confirmed against the fitted object rather than
  // assumed, which is why the generated leaf values are used verbatim.
  //
  // The imputer above is why every comparison uses a value: no input reaches a
  // node as missing, so the exported `missing_go_to_left` flag is part of the
  // recorded tree but not part of this traversal. It is kept in the generated
  // header because it is a property of the fitted model, not of this walker.
  double total = research_exif_data::kBaseline;
  for (std::size_t tree = 0; tree < research_exif_data::kTreeCount; ++tree) {
    // Child indices are relative to their own tree, exactly as scikit-learn
    // stores them; `kNodes` is one flat array. Keeping the walker's index
    // relative and adding the tree's base only to reach `kNodes` is what keeps
    // the exported arrays a faithful copy of the fitted object rather than a
    // renumbered approximation of it.
    const std::size_t base = research_exif_data::kTreeOffsets[tree];
    const std::size_t count = research_exif_data::kTreeOffsets[tree + 1] - base;
    std::size_t node = 0;
    while (!research_exif_data::kNodes[base + node].is_leaf) {
      const auto& current = research_exif_data::kNodes[base + node];
      const bool go_left =
          values[static_cast<std::size_t>(current.feature)] <= current.threshold;
      const std::int32_t child = go_left ? current.left : current.right;
      if (child < 0 || static_cast<std::size_t>(child) >= count) {
        // A child index outside its own tree means the exported arrays and the
        // offsets disagree. Continuing would silently read a neighbouring tree.
        return std::numeric_limits<double>::quiet_NaN();
      }
      node = static_cast<std::size_t>(child);
    }
    total += research_exif_data::kNodes[base + node].value;
  }
  return total;
}

}  // namespace hyperdr

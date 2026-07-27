#pragma once

// The structured record of a run, and of a look.
//
// The report is what the browser panel reads back after a conversion and what
// makes a rendering regression visible without opening the image: it carries the
// selected exposure, the headroom actually used, the gain distribution, and the
// below-shoulder difference that is supposed to stay at zero.

#include "hyperdr/app/settings.hpp"
#include "hyperdr/look/curve.hpp"

#include <filesystem>
#include <string>
#include <vector>

namespace hyperdr {

[[nodiscard]] std::string run_report_json(const std::vector<FileResult>& results,
                                          const ConvertOptions& options);
void write_run_report(const std::filesystem::path& path,
                      const std::vector<FileResult>& results,
                      const ConvertOptions& options);

// The tone curve as data, for the panel's live preview. Emitted here rather than
// in the look module because it also reports the gain-map settings the curve was
// built from, which are a level above the curve itself.
[[nodiscard]] std::string look_curve_json(const GainMapOptions& gain, unsigned samples);

}  // namespace hyperdr

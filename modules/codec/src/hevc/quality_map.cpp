#include "hevc/hevc.hpp"

#include <algorithm>

namespace hyperdr::codec::hevc {

// Provisional: a straight line onto VideoToolbox's 0-1 quality scale, which is
// monotonic and keeps `quality` meaning "higher is better". P3a-2 replaces it
// with a table calibrated against the sample set.
float vt_quality(int quality) {
  return static_cast<float>(std::clamp(quality, 0, 100)) / 100.0F;
}

}  // namespace hyperdr::codec::hevc

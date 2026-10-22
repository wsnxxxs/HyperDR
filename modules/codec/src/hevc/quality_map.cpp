#include "hevc/hevc.hpp"

#include <algorithm>
#include <iterator>

namespace hyperdr::codec::hevc {

// Calibrated with the local ImageIO / VT laboratory in tests/quality. Color
// samples use nearest quantization: preserving added TPDF noise at high quality
// cost much more data and lowered fidelity. Main10 is calibrated by transfer.
// A gain map has only eight useful bits; q95 spent most of the file on its
// quantization noise. Cap that stream independently, without reducing the base.
// Framed gain keeps its established q95 so the exact-zero E5 gate is unchanged.
float vt_quality(int quality, bool main10, QualityRole role, int transfer) {
  const float q = static_cast<float>(std::clamp(quality, 0, 100));
  if (role == QualityRole::FramedGain)
    return .95F;
  if (role == QualityRole::Gain)
    return std::min(q / 100.F, .85F);
  if (main10) {
    // Small tent correction: endpoints stay 0 and 1; q90 matches the system's
    // useful bitrate region separately for P3, PQ and HLG.
    const float correction = transfer == 18   ? .04F
                             : transfer == 16 ? .02F
                                              : .01F;
    return q / 100.F - correction * std::min(q / 90.F, (100.F - q) / 10.F);
  }
  constexpr float input[] = {0, 50, 75, 90, 95, 100};
  constexpr float output[] = {0, .70F, .83F, .89F, .94F, 1};
  for (unsigned i = 1; i < std::size(input); ++i) {
    if (q <= input[i]) {
      const float t = (q - input[i - 1]) / (input[i] - input[i - 1]);
      return output[i - 1] + t * (output[i] - output[i - 1]);
    }
  }
  return 1.F;
}

} // namespace hyperdr::codec::hevc

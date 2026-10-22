#pragma once

#include "hevc/hevc.hpp"

namespace hyperdr::codec::testing {
// Only a confirmed absence of the encoder is an allowed skip. Probe damage
// and a missing required Main10 profile must fail the actual codec gate.
inline int probe_exit_code(const hevc::EncoderCaps& caps) {
  if (!caps.main8 && !caps.main10 && caps.reason_code == hevc::kReasonUnavailable) return 77;
  return caps.main8 && caps.main10 && caps.reason_code.empty() ? 0 : 1;
}
}  // namespace hyperdr::codec::testing

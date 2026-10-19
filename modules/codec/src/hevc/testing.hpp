#pragma once
// Private test entry points; no engine or ABI surface.
#include "hevc/hevc.hpp"
namespace hyperdr::codec::hevc::testing {
struct AuditedSequence {
  EncodedSequence filtered;
  // Exactly the same samples, with only the original UNSPEC NALs restored.
  EncodedSequence with_unspecified;
};
[[nodiscard]] AuditedSequence encode_audited(std::size_t count,const TileProducer& produce,
                                            const EncodeParams& params);
[[nodiscard]] std::vector<std::uint8_t> repack_sample(const std::vector<std::uint8_t>& sample,
    int length_size,const EncodedSequence& parameter_sets);
}

#ifdef HYPERDR_HEIF_CHROMA_DIAGNOSTIC
namespace hyperdr::codec::hevc::testing {
// Available only in the separately compiled diagnostic executable.
void set_nearest_chroma(bool nearest);
void set_rounded_chroma(bool rounded);
void set_integer_rgb(bool integer);
}
#endif

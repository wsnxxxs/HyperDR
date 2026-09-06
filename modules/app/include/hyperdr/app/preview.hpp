#pragma once
#include "hyperdr/app/settings.hpp"
#include <vector>

namespace hyperdr {
// Aligned float SDR base plus encoded monochrome gain, reconstructed by the viewer.
std::vector<std::uint8_t> compact_preview_packet(const GainMapResult& result,
    const DecodeInfo& decode, const InputDescription& input);
}

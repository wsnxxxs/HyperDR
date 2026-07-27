#include "hyperdr/app/settings.hpp"

#include "hyperdr/codec/availability.hpp"

#include <algorithm>
#include <stdexcept>

namespace hyperdr {

void validate_convert_options(const ConvertOptions& options) {
  if (options.output_directory.empty()) {
    throw std::invalid_argument("--output is required");
  }
  if (options.decode_intent == DecodeIntent::Preview &&
      options.preview_max_edge == 0) {
    throw std::invalid_argument(
        "fast preview requires --preview-max-edge");
  }
  if ((options.decode_intent == DecodeIntent::Preview) !=
      options.raw.half_size) {
    throw std::invalid_argument(
        "RAW half-size decoding is permitted only for explicit previews");
  }
  if (options.encoding == HdrEncoding::UltraHdr && options.depth != 8) {
    throw std::invalid_argument(
        "Ultra HDR JPEG uses an 8-bit SDR base and requires --depth 8");
  }
  if (is_hlg_encoding(options.encoding) && !options.gain.auto_headroom &&
      options.gain.headroom_stops > kHlgHeadroomStops) {
    throw std::invalid_argument(
        "HLG headroom cannot exceed 2.3 stops at 203-nit diffuse white");
  }
  // Ranges for the individual settings are enforced by the schema on the way in;
  // this catches the internal look parameters and the renderer's own invariants.
  validate_gain_map_options(options.gain);
}

}  // namespace hyperdr

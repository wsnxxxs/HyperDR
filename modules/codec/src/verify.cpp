// Decode-verification for whatever an encoding just wrote.
//
// The per-format checks live beside their encoders; this is the one dispatch
// that turns "the format I asked for" into "the check that proves the file
// opens". It is shared by the converter and by the packaging entry point so an
// export cannot be published unverified because two call sites drifted.

#include "hyperdr/codec/encoders.hpp"

// The codec-less build defines this entry point in unavailable.cpp instead,
// where every other encoder is a "needs codecs" failure.
#if HYPERDR_WITH_CODECS

namespace hyperdr {

void verify_encoded_output(const std::vector<std::uint8_t>& bytes,
                           HdrEncoding encoding) {
  if (encoding == HdrEncoding::SdrTiff) verify_sdr_tiff(bytes);
  else if (encoding == HdrEncoding::SdrJpeg) verify_sdr_jpeg(bytes);
  else if (encoding == HdrEncoding::IsoGainMapJpeg) verify_gain_map_jpeg(bytes);
  else if (is_avif_encoding(encoding)) verify_avif_decodable(bytes);
  else verify_heic_decodable(bytes, encoding);
}

}  // namespace hyperdr

#endif  // HYPERDR_WITH_CODECS

#pragma once
#include <optional>

#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
namespace hyperdr::codec::hevc::testing {
// Synthetic decoder fixtures recorded with VT on a physical Mac. Set
// HYPERDR_RECORD_HEVC_FIXTURES=1 to regenerate them with the test-only encoder.
struct FixtureGeometry {
  unsigned width{512}, height{512}, depth{8}, chroma{1};
  bool full_range{true};
  std::optional<unsigned> chroma_location;
};
struct DecodeFixture {
  HvcConfig config;
  std::vector<std::uint8_t> sample;
  DecodedPicture input;
};
[[nodiscard]] DecodeFixture fixture(const FixtureGeometry&);
}  // namespace hyperdr::codec::hevc::testing

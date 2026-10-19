#pragma once
#include <optional>

#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
namespace hyperdr::codec::hevc::testing {
// Test-only arbitrary-size/profile VT encoder; no product encoder changes.
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
[[nodiscard]] DecodeFixture encode(const FixtureGeometry&);
}  // namespace hyperdr::codec::hevc::testing

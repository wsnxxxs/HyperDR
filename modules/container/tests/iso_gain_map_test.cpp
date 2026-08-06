#include "hyperdr/container/iso_gain_map.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_invalid_tmap_metadata() {
  hyperdr::GainMapMetadata metadata;
  const auto valid = hyperdr::serialize_tmap_payload(metadata);
  auto reserved_flags = valid;
  reserved_flags[5] |= 1;
  bool rejected = false;
  try {
    (void)hyperdr::parse_tmap_payload(reserved_flags);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "reserved tmap flags were accepted");

  auto invalid_range = valid;
  // gain_min starts at byte 22, gain_max at byte 30. Encode min=2, max=1.
  invalid_range[25] = 2;
  invalid_range[33] = 1;
  rejected = false;
  try {
    (void)hyperdr::parse_tmap_payload(invalid_range);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "invalid tmap gain range was accepted");
}

void test_common_denominator_round_trip() {
  hyperdr::GainMapMetadata metadata;
  metadata.common_denominator = true;
  metadata.base_headroom = {0, 1000000};
  metadata.alternate_headroom = {1807617, 1000000};
  metadata.gain_min = {-83801, 1000000};
  metadata.gain_max = {1807617, 1000000};
  metadata.gamma = {819824, 1000000};
  metadata.base_offset = {10, 1000000};
  metadata.alternate_offset = {10, 1000000};
  const auto payload = hyperdr::serialize_tmap_payload(metadata);
  require(payload.size() == 38, "common-denominator payload has wrong size");
  const auto decoded = hyperdr::parse_tmap_payload(payload);
  require(decoded.common_denominator, "common-denominator flag was lost");
  require(decoded.gain_min.numerator == metadata.gain_min.numerator &&
              decoded.gain_max.numerator == metadata.gain_max.numerator &&
              decoded.gamma.numerator == metadata.gamma.numerator,
          "common-denominator numerators changed");
}

}  // namespace

int main() {
  try {
    test_invalid_tmap_metadata();
    test_common_denominator_round_trip();
    std::cout << "ISO gain-map metadata tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}

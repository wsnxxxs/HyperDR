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

std::vector<std::uint8_t> bytes_from_hex(const std::string& hex) {
  if (hex.size() % 2 != 0) throw std::runtime_error("odd hex fixture length");
  std::vector<std::uint8_t> bytes;
  bytes.reserve(hex.size() / 2);
  for (std::size_t index = 0; index < hex.size(); index += 2) {
    bytes.push_back(static_cast<std::uint8_t>(
        std::stoul(hex.substr(index, 2), nullptr, 16)));
  }
  return bytes;
}

template <typename Function>
void require_invalid(Function&& function, const char* message) {
  bool rejected = false;
  try {
    function();
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, message);
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

void test_multichannel_round_trip() {
  hyperdr::GainMapMetadata metadata;
  metadata.flags |= 0x80U;
  metadata.alternate_headroom = {3, 1};
  metadata.channels = {
      {{-1, 1}, {2, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {3, 1}, {2, 1}, {1, 100}, {2, 100}},
      {{-2, 1}, {1, 1}, {1, 2}, {-1, 100}, {0, 1}},
  };

  const auto payload = hyperdr::serialize_tmap_payload(metadata);
  require(payload.size() == 142,
          "three-channel non-common payload has wrong size");
  const auto decoded = hyperdr::parse_tmap_payload(
      payload, hyperdr::GainMapWriterProfile::iso_generic);
  require(hyperdr::gain_map_channel_count(decoded) == 3,
          "multichannel flag or channel axis was lost");
  require(hyperdr::gain_map_channel(decoded, 0).gain_min.numerator == -1 &&
              hyperdr::gain_map_channel(decoded, 1).gamma.numerator == 2 &&
              hyperdr::gain_map_channel(decoded, 2).gain_max.numerator == 1,
          "per-channel metadata changed during round trip");
  require(hyperdr::serialize_tmap_payload(decoded) == payload,
          "multichannel payload was not byte-stable");
}

void test_writer_profiles_are_explicit() {
  hyperdr::GainMapMetadata apple;
  hyperdr::validate_gain_map_metadata(
      apple, hyperdr::GainMapWriterProfile::apple_strict);

  auto generic_single = apple;
  generic_single.gain_max = {2, 1};
  hyperdr::validate_gain_map_metadata(
      generic_single, hyperdr::GainMapWriterProfile::iso_generic);
  require_invalid(
      [&] {
        hyperdr::validate_gain_map_metadata(
            generic_single, hyperdr::GainMapWriterProfile::apple_strict);
      },
      "apple_strict accepted a non-Apple gain/headroom relationship");

  auto generic_rgb = apple;
  generic_rgb.flags |= 0x80U;
  generic_rgb.channels = {
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {2, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{-1, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
  };
  hyperdr::validate_gain_map_metadata(
      generic_rgb, hyperdr::GainMapWriterProfile::iso_generic);
  require_invalid(
      [&] {
        hyperdr::validate_gain_map_metadata(
            generic_rgb, hyperdr::GainMapWriterProfile::apple_strict);
      },
      "apple_strict accepted three-channel ISO metadata");
}

void test_registered_profiles_against_corpus_payloads() {
  // Raw ToneMapImage payloads from the frozen corpora. Keeping the payloads,
  // rather than private image files, makes the regression deterministic while
  // preserving exactly the writer flags and rationals under test.
  // Apple: apl_00df38e01131375a5553 (62-byte, one-channel payload).
  const auto apple_payload = bytes_from_hex(
      "00000000004000000000000f4240002a595f000f4240fff310d8000f4240"
      "002a595f000f42400012abd1000f42400000000a000f42400000000a000f4240");
  const auto apple = hyperdr::parse_tmap_payload(
      apple_payload, hyperdr::GainMapWriterProfile::apple_strict);
  require(hyperdr::gain_map_channel_count(apple) == 1,
          "apple_strict rejected the registered Apple payload");

  // Indigo: idg_cf30ade95612ba79b755 (142-byte, three-channel payload).
  const auto indigo_payload = bytes_from_hex(
      "0000000000c000000000000000010000000400000001fffffae500000100"
      "000007f500000200000000010000000100000001000000400000000100000040"
      "fffffb3100000200000007c90000020000000001000000010000000100000040"
      "0000000100000040fffffbd900000100000007f5000002000000000100000001"
      "00000001000000400000000100000040");
  const auto indigo = hyperdr::parse_tmap_payload(
      indigo_payload, hyperdr::GainMapWriterProfile::iso_generic);
  require(hyperdr::gain_map_channel_count(indigo) == 3,
          "iso_generic rejected the registered Indigo payload");
  require_invalid(
      [&] {
        (void)hyperdr::parse_tmap_payload(
            indigo_payload, hyperdr::GainMapWriterProfile::apple_strict);
      },
      "apple_strict accepted the registered Indigo payload");

  // Every Indigo capture carries two APP2 segments under the ISO 21496-1 URN:
  // this five-zero-byte stub on the primary image, and the real payload on the
  // gain map. Callers pick between them by parseability, so the stub being
  // rejected is what keeps that selection honest -- if it ever parsed, the
  // extractor would silently prefer the primary image's placeholder.
  // Measured across all 109 Indigo captures on 2026-08-10: byte-identical
  // stub, always the first candidate, never accepted under either profile.
  const auto indigo_primary_stub = bytes_from_hex("0000000000");
  require_invalid(
      [&] {
        (void)hyperdr::parse_tmap_payload(
            indigo_primary_stub, hyperdr::GainMapWriterProfile::iso_generic);
      },
      "iso_generic accepted the Indigo primary-image stub");
  require_invalid(
      [&] {
        (void)hyperdr::parse_tmap_payload(
            indigo_primary_stub, hyperdr::GainMapWriterProfile::apple_strict);
      },
      "apple_strict accepted the Indigo primary-image stub");
}

// The reader briefly required gain_max == alternate_headroom. Both renderers
// violate that for ordinary scenes, and because verify_heic_decodable parses
// the file it has just written, conversion failed outright -- reported as
// "failed semantic structure verification", because inspect_heif turns a parse
// error into structurally_valid = false.
void test_gain_range_is_independent_of_declared_headroom() {
  hyperdr::GainMapMetadata metadata;
  // A flat bright field: 2.03 stops of coding range against 2.00 stops of
  // requested headroom, which is what the photographic renderer produces.
  metadata.alternate_headroom = {2000000, 1000000};
  metadata.gain_max = {2031690, 1000000};
  metadata.gain_min = {0, 1000000};
  const auto decoded =
      hyperdr::parse_tmap_payload(hyperdr::serialize_tmap_payload(metadata));
  require(decoded.gain_max.numerator == metadata.gain_max.numerator &&
              decoded.alternate_headroom.numerator ==
                  metadata.alternate_headroom.numerator,
          "a gain range wider than the declared headroom was not preserved");

  // And the saturated low-luminance case: chroma-limited gain with no
  // luminance headroom at all.
  metadata.alternate_headroom = {0, 1000000};
  metadata.gain_max = {487600, 1000000};
  const auto saturated =
      hyperdr::parse_tmap_payload(hyperdr::serialize_tmap_payload(metadata));
  require(saturated.gain_max.numerator == 487600,
          "gain range with zero declared headroom was not preserved");
}

}  // namespace

int main() {
  try {
    test_invalid_tmap_metadata();
    test_common_denominator_round_trip();
    test_multichannel_round_trip();
    test_writer_profiles_are_explicit();
    test_registered_profiles_against_corpus_payloads();
    test_gain_range_is_independent_of_declared_headroom();
    std::cout << "ISO gain-map metadata tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}

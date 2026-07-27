#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/heif_tmap.hpp"

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

void put16(std::vector<std::uint8_t>& out, std::uint16_t v) {
  out.push_back(static_cast<std::uint8_t>(v >> 8));
  out.push_back(static_cast<std::uint8_t>(v));
}

void put32(std::vector<std::uint8_t>& out, std::uint32_t v) {
  out.push_back(static_cast<std::uint8_t>(v >> 24));
  out.push_back(static_cast<std::uint8_t>(v >> 16));
  out.push_back(static_cast<std::uint8_t>(v >> 8));
  out.push_back(static_cast<std::uint8_t>(v));
}

void append_box(std::vector<std::uint8_t>& out, const char* type,
                const std::vector<std::uint8_t>& payload) {
  put32(out, static_cast<std::uint32_t>(payload.size() + 8));
  out.insert(out.end(), type, type + 4);
  out.insert(out.end(), payload.begin(), payload.end());
}

void test_zero_width_iloc_extents_are_rejected() {
  std::vector<std::uint8_t> infe{2, 0, 0, 0};
  put16(infe, 1); put16(infe, 0);
  infe.insert(infe.end(), {'t', 'm', 'a', 'p', 'x', 0});
  std::vector<std::uint8_t> iinf{0, 0, 0, 0};
  put16(iinf, 1);
  append_box(iinf, "infe", infe);

  std::vector<std::uint8_t> iloc{0, 0, 0, 0, 0x00, 0x00};
  put16(iloc, 1);
  put16(iloc, 1); put16(iloc, 0); put16(iloc, 0); put16(iloc, 0xFFFF);

  std::vector<std::uint8_t> meta{0, 0, 0, 0};
  append_box(meta, "iinf", iinf);
  append_box(meta, "iloc", iloc);
  std::vector<std::uint8_t> file;
  append_box(file, "meta", meta);
  bool rejected = false;
  try {
    (void)hyperdr::extract_tmap_payload(file);
  } catch (const std::runtime_error&) {
    rejected = true;
  }
  require(rejected, "zero-width iloc extents were accepted");
}

void test_deep_box_nesting_is_rejected() {
  std::vector<std::uint8_t> nested;
  for (unsigned depth = 0; depth < 65; ++depth) {
    std::vector<std::uint8_t> parent;
    append_box(parent, "ipco", nested);
    nested = std::move(parent);
  }
  std::vector<std::uint8_t> file;
  put32(file, 20); file.insert(file.end(), {'f','t','y','p','h','e','i','c',0,0,0,0});
  file.insert(file.end(), nested.begin(), nested.end());
  const auto inspection = hyperdr::inspect_heif(file);
  require(!inspection.structurally_valid, "deep HEIF box nesting was accepted");
}

void test_minor_version_is_not_a_brand() {
  // A plain HEIC whose minor_version happens to spell "tmap" must not be
  // routed into the Adaptive HDR path.
  std::vector<std::uint8_t> file;
  put32(file, 16);
  file.insert(file.end(), {'f','t','y','p','h','e','i','c','t','m','a','p'});
  const auto inspection = hyperdr::inspect_heif(file);
  require(inspection.has_heic_brand, "major brand was not read");
  require(!inspection.has_tmap_brand, "ftyp minor version was treated as a brand");
}

void test_bmff_bounds_and_brands() {
  std::vector<std::uint8_t> file;
  put32(file, 24); file.insert(file.end(), {'f','t','y','p','h','e','i','c',0,0,0,0,'m','i','f','1','t','m','a','p'});
  put32(file, 8); file.insert(file.end(), {'f','r','e','e'});
  const auto inspection = hyperdr::inspect_heif(file);
  require(inspection.structurally_valid && inspection.has_heic_brand && inspection.has_tmap_brand,
          "BMFF brand inspection failed");
  file.pop_back();
  require(!hyperdr::inspect_heif(file).structurally_valid, "truncated BMFF accepted");
}

}  // namespace

int main() {
  try {
    test_bmff_bounds_and_brands();
    test_zero_width_iloc_extents_are_rejected();
    test_deep_box_nesting_is_rejected();
    test_minor_version_is_not_a_brand();
    std::cout << "HEIF inspection tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}

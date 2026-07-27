// Does `--highlight-recovery` actually reach the sensor data?
//
// The setting travels a long way -- panel control, CLI flag, settings schema,
// ConvertOptions, RawDecodeOptions, LibRaw's `params.highlight` -- and every
// link in that chain compiled fine while the panel showed a picture no mode
// could change. Nothing asserted the only thing that matters: that two modes
// produce two different images. The resume-state test checks that the modes
// produce different *cache keys*, which is a statement about strings.
//
// RAW files cannot be checked in (`.gitignore` excludes them, and a camera file
// is tens of megabytes), so the fixture is written here: a minimal uncompressed
// RGGB DNG with a dark gradient and one blown disc whose three channels
// saturate at different raw levels. That last detail is the whole point.
// Highlight recovery only has something to do when the channels clip unevenly
// *and* the white balance is not unity -- LibRaw changes its WB normalisation
// between clip and non-clip modes, and its blend/recover passes key
// off the resulting per-channel clip levels. A fixture shot with neutral WB
// produces four bit-identical images and proves nothing, which is how the first
// version of this test managed to pass while asserting the wrong thing.

#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

// --- a minimal DNG writer --------------------------------------------------

void put16(std::vector<std::uint8_t>& out, std::uint16_t value) {
  out.push_back(static_cast<std::uint8_t>(value & 0xFF));
  out.push_back(static_cast<std::uint8_t>(value >> 8));
}

void put32(std::vector<std::uint8_t>& out, std::uint32_t value) {
  for (int i = 0; i < 4; ++i) out.push_back(static_cast<std::uint8_t>((value >> (8 * i)) & 0xFF));
}

std::vector<std::uint8_t> bytes16(std::uint16_t value) {
  std::vector<std::uint8_t> out;
  put16(out, value);
  return out;
}

std::vector<std::uint8_t> bytes32(std::uint32_t value) {
  std::vector<std::uint8_t> out;
  put32(out, value);
  return out;
}

std::vector<std::uint8_t> rational(std::uint32_t numerator, std::uint32_t denominator) {
  std::vector<std::uint8_t> out;
  put32(out, numerator);
  put32(out, denominator);
  return out;
}

std::vector<std::uint8_t> srational(std::int32_t numerator, std::int32_t denominator) {
  return rational(static_cast<std::uint32_t>(numerator), static_cast<std::uint32_t>(denominator));
}

void append(std::vector<std::uint8_t>& out, const std::vector<std::uint8_t>& more) {
  out.insert(out.end(), more.begin(), more.end());
}

constexpr std::uint32_t kWidth = 96;
constexpr std::uint32_t kHeight = 80;
constexpr std::uint32_t kCropLeft = 8;
constexpr std::uint32_t kCropTop = 8;
constexpr std::uint32_t kCropWidth = 80;
constexpr std::uint32_t kCropHeight = 64;
constexpr std::uint16_t kWhiteLevel = 65535;

// One CFA site's raw value. RGGB: even row/even column is red, odd/odd is blue,
// the rest green.
unsigned cfa_channel(std::uint32_t x, std::uint32_t y) {
  if (y % 2 == 0 && x % 2 == 0) return 0;
  if (y % 2 == 1 && x % 2 == 1) return 2;
  return 1;
}

std::vector<std::uint8_t> synthetic_cfa() {
  // Deliberately dark, so that "the modes disagree only in the highlights" is a
  // statement about a small bright region rather than about most of the frame.
  constexpr std::array<double, 3> kSceneGain{1.0, 0.75, 0.45};
  // The disc saturates red and green outright while blue stops well short: the
  // uneven clipping that highlight recovery exists to repair.
  constexpr std::array<double, 3> kBlown{65535.0, 65535.0, 41000.0};
  const double centre_x = kWidth * 0.65;
  const double centre_y = kHeight * 0.40;
  const double radius = kWidth * 0.22;

  std::vector<std::uint8_t> raster;
  raster.reserve(static_cast<std::size_t>(kWidth) * kHeight * 2);
  for (std::uint32_t y = 0; y < kHeight; ++y) {
    for (std::uint32_t x = 0; x < kWidth; ++x) {
      const unsigned channel = cfa_channel(x, y);
      const double dx = static_cast<double>(x) - centre_x;
      const double dy = static_cast<double>(y) - centre_y;
      const bool blown = dx * dx + dy * dy < radius * radius;
      const double value = blown ? kBlown[channel]
                                 : (600.0 + 110.0 * x) * kSceneGain[channel];
      const auto clamped = static_cast<std::uint16_t>(
          std::clamp(value, 0.0, static_cast<double>(kWhiteLevel)));
      put16(raster, clamped);
    }
  }
  return raster;
}

struct Field {
  std::uint16_t tag;
  std::uint16_t type;   // 1 BYTE, 2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL, 10 SRATIONAL
  std::uint32_t count;
  std::vector<std::uint8_t> payload;
  bool is_strip_offset{false};
};

// A little-endian, single-strip, uncompressed CFA DNG. Only the tags LibRaw
// needs to treat the file as a raw mosaic are written; anything it can default,
// it defaults.
void write_synthetic_dng(const std::filesystem::path& path,
                         std::uint32_t crop_width = kCropWidth,
                         std::uint32_t crop_height = kCropHeight) {
  const auto raster = synthetic_cfa();
  const std::string model = "HyperDR Synthetic";

  std::vector<std::uint8_t> colour_matrix;
  for (int i = 0; i < 9; ++i) {
    append(colour_matrix, srational(i % 4 == 0 ? 10000 : 0, 10000));
  }
  // A daylight-ish as-shot neutral. Unity here would make every highlight mode
  // agree; see the comment at the top of the file.
  std::vector<std::uint8_t> as_shot_neutral;
  append(as_shot_neutral, rational(4500, 10000));
  append(as_shot_neutral, rational(10000, 10000));
  append(as_shot_neutral, rational(6500, 10000));

  std::vector<std::uint8_t> model_ascii(model.begin(), model.end());
  model_ascii.push_back(0);

  std::vector<Field> fields{
      {254, 4, 1, bytes32(0), false},                       // NewSubfileType
      {256, 4, 1, bytes32(kWidth), false},                  // ImageWidth
      {257, 4, 1, bytes32(kHeight), false},                 // ImageLength
      {258, 3, 1, bytes16(16), false},                      // BitsPerSample
      {259, 3, 1, bytes16(1), false},                       // Compression: none
      {262, 3, 1, bytes16(32803), false},                   // PhotometricInterpretation: CFA
      {273, 4, 1, bytes32(0), true},                        // StripOffsets, patched below
      {274, 3, 1, bytes16(6), false},                       // Orientation: 90 degrees CW
      {277, 3, 1, bytes16(1), false},                       // SamplesPerPixel
      {278, 4, 1, bytes32(kHeight), false},                 // RowsPerStrip
      {279, 4, 1, bytes32(static_cast<std::uint32_t>(raster.size())), false},
      {284, 3, 1, bytes16(1), false},                       // PlanarConfiguration
      {33421, 3, 2, [] { auto v = bytes16(2); append(v, bytes16(2)); return v; }(), false},
      {33422, 1, 4, {0, 1, 1, 2}, false},                   // CFAPattern: RGGB
      {50706, 1, 4, {1, 4, 0, 0}, false},                   // DNGVersion
      {50707, 1, 4, {1, 1, 0, 0}, false},                   // DNGBackwardVersion
      {50708, 2, static_cast<std::uint32_t>(model_ascii.size()), model_ascii, false},
      {50714, 3, 1, bytes16(0), false},                     // BlackLevel
      {50717, 4, 1, bytes32(kWhiteLevel), false},           // WhiteLevel
      {50719, 4, 2, [] {
         auto v = bytes32(kCropLeft);
         append(v, bytes32(kCropTop));
         return v;
       }(), false},                                         // DefaultCropOrigin
      {50720, 4, 2, [crop_width, crop_height] {
         auto v = bytes32(crop_width);
         append(v, bytes32(crop_height));
         return v;
       }(), false},                                         // DefaultCropSize
      {50721, 10, 9, colour_matrix, false},                 // ColorMatrix1
      {50728, 5, 3, as_shot_neutral, false},                // AsShotNeutral
      {50778, 3, 1, bytes16(21), false},                    // CalibrationIlluminant1: D65
  };
  std::sort(fields.begin(), fields.end(),
            [](const Field& a, const Field& b) { return a.tag < b.tag; });

  constexpr std::uint32_t kHeaderSize = 8;
  const auto directory_size =
      static_cast<std::uint32_t>(2 + 12 * fields.size() + 4);
  const std::uint32_t overflow_offset = kHeaderSize + directory_size;

  // Values longer than four bytes live after the directory and the field holds
  // their offset instead.
  std::vector<std::uint8_t> overflow;
  std::vector<std::array<std::uint8_t, 4>> inline_values(fields.size());
  for (std::size_t i = 0; i < fields.size(); ++i) {
    std::array<std::uint8_t, 4> slot{0, 0, 0, 0};
    if (fields[i].payload.size() <= 4) {
      std::memcpy(slot.data(), fields[i].payload.data(), fields[i].payload.size());
    } else {
      const auto at = static_cast<std::uint32_t>(overflow_offset + overflow.size());
      const auto encoded = bytes32(at);
      std::memcpy(slot.data(), encoded.data(), 4);
      append(overflow, fields[i].payload);
      if (overflow.size() % 2 != 0) overflow.push_back(0);  // TIFF wants even offsets
    }
    inline_values[i] = slot;
  }
  const auto strip_offset =
      static_cast<std::uint32_t>(overflow_offset + overflow.size());
  for (std::size_t i = 0; i < fields.size(); ++i) {
    if (!fields[i].is_strip_offset) continue;
    const auto encoded = bytes32(strip_offset);
    std::memcpy(inline_values[i].data(), encoded.data(), 4);
  }

  std::vector<std::uint8_t> file;
  file.push_back('I');
  file.push_back('I');
  put16(file, 42);
  put32(file, kHeaderSize);
  put16(file, static_cast<std::uint16_t>(fields.size()));
  for (std::size_t i = 0; i < fields.size(); ++i) {
    put16(file, fields[i].tag);
    put16(file, fields[i].type);
    put32(file, fields[i].count);
    file.insert(file.end(), inline_values[i].begin(), inline_values[i].end());
  }
  put32(file, 0);  // no next IFD
  append(file, overflow);
  append(file, raster);

  hyperdr::write_binary_file_atomic(path, file, true);
}

// --- comparisons -----------------------------------------------------------

float max_abs_difference(const hyperdr::FloatImage& a, const hyperdr::FloatImage& b) {
  require(a.width == b.width && a.height == b.height,
          "highlight modes changed the decoded dimensions");
  float worst = 0.0F;
  for (std::size_t i = 0; i < a.pixels.size(); ++i) {
    worst = std::max(worst, std::fabs(a.pixels[i] - b.pixels[i]));
  }
  return worst;
}

// After the fixture's 90-degree rotation, the top-left region maps back to the
// dark, low-x end of the sensor gradient and misses the blown disc entirely.
struct Region {
  std::uint32_t x0, y0, x1, y1;
};

Region shadow_region(const hyperdr::FloatImage& image) {
  return {0, 0, image.width / 3, image.height / 3};
}

float max_abs_difference_in(const hyperdr::FloatImage& a, const hyperdr::FloatImage& b,
                            const Region& region) {
  float worst = 0.0F;
  for (std::uint32_t y = region.y0; y < region.y1; ++y) {
    for (std::uint32_t x = region.x0; x < region.x1; ++x) {
      for (unsigned c = 0; c < 3; ++c) {
        worst = std::max(worst, std::fabs(a.at(x, y, c) - b.at(x, y, c)));
      }
    }
  }
  return worst;
}

float peak_in(const hyperdr::FloatImage& image, const Region& region) {
  float peak = 0.0F;
  for (std::uint32_t y = region.y0; y < region.y1; ++y) {
    for (std::uint32_t x = region.x0; x < region.x1; ++x) {
      for (unsigned c = 0; c < 3; ++c) peak = std::max(peak, image.at(x, y, c));
    }
  }
  return peak;
}

float median_luminance(const hyperdr::FloatImage& image) {
  std::vector<float> luminance;
  luminance.reserve(static_cast<std::size_t>(image.width) * image.height);
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      luminance.push_back(hyperdr::p3_luminance(
          image.at(x, y, 0), image.at(x, y, 1), image.at(x, y, 2)));
    }
  }
  const auto middle = luminance.begin() + luminance.size() / 2;
  std::nth_element(luminance.begin(), middle, luminance.end());
  return *middle;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc == 2) {
    try {
      constexpr std::array<std::pair<const char*, hyperdr::HighlightRecovery>, 4>
          kModes{{
              {"clip", hyperdr::HighlightRecovery::Clip},
              {"unclip", hyperdr::HighlightRecovery::Unclip},
              {"blend", hyperdr::HighlightRecovery::Blend},
              {"reconstruct", hyperdr::HighlightRecovery::Reconstruct},
          }};
      std::array<float, kModes.size()> medians{};
      for (std::size_t i = 0; i < kModes.size(); ++i) {
        hyperdr::RawDecodeOptions options;
        options.highlight_recovery = kModes[i].second;
        const auto decoded =
            hyperdr::decode_image(std::filesystem::path(argv[1]), options)
                .linear_p3;
        medians[i] = median_luminance(decoded);
        std::cout << kModes[i].first << ": " << decoded.width << 'x'
                  << decoded.height << ", median luminance = " << medians[i]
                  << '\n';
      }
      for (std::size_t i = 0; i < medians.size(); ++i) {
        for (std::size_t j = i + 1; j < medians.size(); ++j) {
          const float difference_ev =
              std::fabs(std::log2(medians[i] / medians[j]));
          require(difference_ev < 0.05F,
                  std::string("external RAW exposure differs by ") +
                      std::to_string(difference_ev) + " EV: " +
                      kModes[i].first + " vs " + kModes[j].first);
        }
      }
      return 0;
    } catch (const std::exception& e) {
      std::cerr << "RAW validation failure: " << e.what() << '\n';
      return 1;
    }
  }

  const auto path = std::filesystem::temp_directory_path() / "hyperdr-highlight-fixture.dng";
  try {
    write_synthetic_dng(path);

    constexpr std::array<std::pair<const char*, hyperdr::HighlightRecovery>, 4> kModes{{
        {"clip", hyperdr::HighlightRecovery::Clip},
        {"unclip", hyperdr::HighlightRecovery::Unclip},
        {"blend", hyperdr::HighlightRecovery::Blend},
        {"reconstruct", hyperdr::HighlightRecovery::Reconstruct},
    }};

    std::vector<hyperdr::FloatImage> decoded;
    for (const auto& [name, mode] : kModes) {
      hyperdr::RawDecodeOptions options;
      options.highlight_recovery = mode;
      auto result = hyperdr::decode_image(path, options);
      require(result.linear_p3.width == kCropHeight &&
                  result.linear_p3.height == kCropWidth,
               std::string("unexpected decoded size for ") + name);
      require(result.decode.target_width == kCropHeight &&
                  result.decode.target_height == kCropWidth,
              std::string("DefaultCrop target not reported for ") + name);
      require(result.decode.default_crop_present,
              std::string("DefaultCrop presence not recorded for ") + name);
      require(result.decode.target_dimensions_applied,
              std::string("applied DefaultCrop was not marked applied for ") + name);
      require(!result.decode.degraded &&
                  result.decode.degradation_reasons.empty(),
              std::string("valid DefaultCrop was rejected for ") + name);
      decoded.push_back(std::move(result.linear_p3));
    }

    // 1. The regression this file exists for: every mode is a different image.
    //    A break anywhere between the flag and `params.highlight` collapses
    //    these differences to zero.
    constexpr float kDistinct = 0.02F;
    for (std::size_t i = 0; i < decoded.size(); ++i) {
      for (std::size_t j = i + 1; j < decoded.size(); ++j) {
        const float difference = max_abs_difference(decoded[i], decoded[j]);
        std::cout << "  " << kModes[i].first << " vs " << kModes[j].first
                  << ": max |diff| = " << difference << '\n';
        require(difference > kDistinct,
                std::string("highlight recovery had no effect: ") + kModes[i].first +
                    " and " + kModes[j].first + " decoded identically");
      }
    }

    // 2. And a different image only where it should be. The three modes that
    //    share LibRaw's headroom-preserving normalisation must agree exactly in
    //    the shadows; if they differ there, something is rescaling the whole
    //    frame rather than repairing highlights.
    const auto region = shadow_region(decoded.front());
    const float shadow_peak = peak_in(decoded[0], region);
    require(shadow_peak < 0.35F,
            "the fixture's shadow region is not dark enough to prove anything");
    for (std::size_t i = 1; i < decoded.size(); ++i) {
      for (std::size_t j = i + 1; j < decoded.size(); ++j) {
        const float difference = max_abs_difference_in(decoded[i], decoded[j], region);
        require(difference < 1e-4F,
                std::string("highlight recovery changed the shadows: ") +
                    kModes[i].first + " vs " + kModes[j].first);
      }
    }

    // 3. The synthetic fixture has non-unity as-shot WB, so it also exercises
    //    the clip/non-clip scale difference. All four modes must retain the
    //    same overall exposure even though their clipped pixels differ.
    std::array<float, kModes.size()> medians{};
    for (std::size_t i = 0; i < decoded.size(); ++i) {
      medians[i] = median_luminance(decoded[i]);
    }
    for (std::size_t i = 0; i < medians.size(); ++i) {
      for (std::size_t j = i + 1; j < medians.size(); ++j) {
        const float difference_ev =
            std::fabs(std::log2(medians[i] / medians[j]));
        require(difference_ev < 0.05F,
                std::string("synthetic RAW exposure differs by ") +
                    std::to_string(difference_ev) + " EV: " +
                    kModes[i].first + " vs " + kModes[j].first);
      }
    }

    // 4. The maxcrop guard rejects implausibly small metadata. That fallback is
    //    allowed, but it must never be silent, and the rejected target must not
    //    be mistakable for a delivered geometry.
    //
    //    The crop is deliberately non-square (32x48) so that the orientation
    //    swap is exercised on this path too: a square fixture cannot tell a
    //    correct swap from a missing one.
    write_synthetic_dng(path, 32, 48);
    const auto rejected = hyperdr::decode_image(path);
    require(rejected.decode.degraded,
            "rejected DefaultCrop was not marked as degraded");
    require(rejected.decode.degradation_reasons.size() == 1 &&
                rejected.decode.degradation_reasons.front() ==
                    "default_crop_rejected",
            "rejected DefaultCrop reason was not recorded");
    require(rejected.decode.default_crop_present,
            "a rejected DefaultCrop is still present in the metadata");
    require(!rejected.decode.target_dimensions_applied,
            "a rejected DefaultCrop must not claim applied target dimensions");
    require(rejected.decode.target_width == 48 &&
                rejected.decode.target_height == 32,
            "rejected DefaultCrop target dimensions were lost or unrotated");
    require(rejected.linear_p3.width == kHeight &&
                rejected.linear_p3.height == kWidth,
            "rejected DefaultCrop did not fall back to the visible area");

    std::filesystem::remove(path);
    std::cout << "RAW highlight recovery test passed (four distinct decodes, "
                 "stable exposure, oriented DefaultCrop)\n";
    return 0;
  } catch (const std::exception& e) {
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    std::cerr << "RAW highlight recovery test failure: " << e.what() << '\n';
    return 1;
  }
}

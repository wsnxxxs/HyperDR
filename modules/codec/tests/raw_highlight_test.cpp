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
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/dng_color.hpp"
#include "../src/internal/raw_highlights.hpp"

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

// Values in millionths, which every matrix below is written in exactly.
std::vector<std::uint8_t> srational_matrix(const hyperdr::Matrix3d& matrix) {
  std::vector<std::uint8_t> out;
  for (const auto& row : matrix) {
    for (const double value : row) {
      append(out, srational(static_cast<std::int32_t>(std::lround(value * 1.0e6)), 1000000));
    }
  }
  return out;
}

// DNG opcode lists are big-endian in any file.
void put_be32(std::vector<std::uint8_t>& out, std::uint32_t value) {
  for (int shift = 24; shift >= 0; shift -= 8) out.push_back(static_cast<std::uint8_t>(value >> shift));
}

void put_be64(std::vector<std::uint8_t>& out, double value) {
  std::uint64_t bits = 0;
  std::memcpy(&bits, &value, sizeof(bits));
  for (int shift = 56; shift >= 0; shift -= 8) out.push_back(static_cast<std::uint8_t>(bits >> shift));
}

std::vector<std::uint8_t> opcode(std::uint32_t id, std::uint32_t flags,
                                 const std::vector<std::uint8_t>& parameters) {
  std::vector<std::uint8_t> out;
  put_be32(out, id);
  put_be32(out, 0x01030000U);
  put_be32(out, flags);
  put_be32(out, static_cast<std::uint32_t>(parameters.size()));
  append(out, parameters);
  return out;
}

std::vector<std::uint8_t> opcode_list(const std::vector<std::vector<std::uint8_t>>& opcodes) {
  std::vector<std::uint8_t> out;
  put_be32(out, static_cast<std::uint32_t>(opcodes.size()));
  for (const auto& entry : opcodes) append(out, entry);
  return out;
}

std::vector<std::uint8_t> rational_vector(const std::array<double, 3>& values) {
  std::vector<std::uint8_t> out;
  for (const double value : values) {
    append(out, rational(static_cast<std::uint32_t>(std::lround(value * 1.0e6)), 1000000));
  }
  return out;
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

std::vector<std::uint8_t> synthetic_cfa(std::uint16_t black_level = 0,
                                        const std::array<std::uint16_t, 3>& field = {}) {
  // Deliberately dark, so that "the modes disagree only in the highlights" is a
  // statement about a small bright region rather than about most of the frame.
  constexpr std::array<double, 3> kSceneGain{1.0, 0.75, 0.45};
  // The disc saturates red and green outright while blue stops well short: the
  // uneven clipping that highlight recovery exists to repair.
  constexpr std::array<double, 3> kBlown{65535.0, 65535.0, 41000.0};
  const double centre_x = kWidth * 0.65;
  const double centre_y = kHeight * 0.40;
  const double radius = kWidth * 0.22;

  // A non-zero field replaces the scene with one flat colour: every site of a
  // channel at that channel's level.
  const bool flat = field[0] != 0 || field[1] != 0 || field[2] != 0;
  std::vector<std::uint8_t> raster;
  raster.reserve(static_cast<std::size_t>(kWidth) * kHeight * 2);
  for (std::uint32_t y = 0; y < kHeight; ++y) {
    for (std::uint32_t x = 0; x < kWidth; ++x) {
      const unsigned channel = cfa_channel(x, y);
      const double dx = static_cast<double>(x) - centre_x;
      const double dy = static_cast<double>(y) - centre_y;
      const bool blown = dx * dx + dy * dy < radius * radius;
      const double value = black_level +
                           (flat    ? static_cast<double>(field[channel])
                            : blown ? kBlown[channel]
                                    : (600.0 + 110.0 * x) * kSceneGain[channel]);
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

// The fixture's camera: raw channels are CIE XYZ scaled so that a D65 white
// gives the as-shot neutral (0.45, 1, 0.65). With the scene white at D65 the
// DNG colour model and LibRaw's D65 matrix agree, so the tests of other
// stages do not depend on which one decoded the file.
constexpr hyperdr::Matrix3d kFixtureColorMatrix{{{0.473457, 0.0, 0.0},
                                                 {0.0, 1.0, 0.0},
                                                 {0.0, 0.0, 0.596846}}};

// A little-endian, single-strip, uncompressed CFA DNG. Only the tags LibRaw
// needs to treat the file as a raw mosaic are written; anything it can default,
// it defaults. `colour_fields`, when given, replace the fixture's ColorMatrix1,
// CalibrationIlluminant1 and AsShotNeutral.
void write_synthetic_dng(const std::filesystem::path& path,
                         std::uint32_t crop_width = kCropWidth,
                         std::uint32_t crop_height = kCropHeight,
                         std::uint32_t crop_left = kCropLeft,
                         std::uint32_t crop_top = kCropTop,
                         std::uint16_t black_level = 0,
                         bool camera_wb = true, bool xtrans = false,
                         bool with_colour_matrix = true,
                         const std::array<std::uint16_t, 3>& field = {},
                         const std::vector<Field>& colour_fields = {},
                         const std::vector<Field>& extra_fields = {}) {
  const auto raster = synthetic_cfa(black_level, field);
  const std::string model = "HyperDR Synthetic";

  // A daylight-ish as-shot neutral. Unity here would make every highlight mode
  // agree; see the comment at the top of the file.
  const auto as_shot_neutral = rational_vector({0.45, 1.0, 0.65});

  std::vector<std::uint8_t> model_ascii(model.begin(), model.end());
  model_ascii.push_back(0);
  const std::vector<std::uint8_t> cfa = xtrans
      ? std::vector<std::uint8_t>{1,2,1,1,0,1, 0,1,0,2,1,2, 1,2,1,1,0,1,
                                  1,0,1,1,2,1, 2,1,2,0,1,0, 1,0,1,1,2,1}
      : std::vector<std::uint8_t>{0,1,1,2};

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
      {33421, 3, 2, [xtrans] { auto v = bytes16(xtrans ? 6 : 2); append(v, bytes16(xtrans ? 6 : 2)); return v; }(), false},
      {33422, 1, static_cast<std::uint32_t>(cfa.size()), cfa, false},
      {50706, 1, 4, {1, 4, 0, 0}, false},                   // DNGVersion
      {50707, 1, 4, {1, 1, 0, 0}, false},                   // DNGBackwardVersion
      {50708, 2, static_cast<std::uint32_t>(model_ascii.size()), model_ascii, false},
      {50714, 3, 1, bytes16(black_level), false},           // BlackLevel
      {50717, 4, 1, bytes32(kWhiteLevel), false},           // WhiteLevel
      {50719, 4, 2, [crop_left, crop_top] {
         auto v = bytes32(crop_left);
         append(v, bytes32(crop_top));
         return v;
       }(), false},                                         // DefaultCropOrigin
      {50720, 4, 2, [crop_width, crop_height] {
         auto v = bytes32(crop_width);
         append(v, bytes32(crop_height));
         return v;
       }(), false},                                         // DefaultCropSize
      {50721, 10, 9, srational_matrix(kFixtureColorMatrix), false},  // ColorMatrix1
      {50728, 5, 3, as_shot_neutral, false},                // AsShotNeutral
      {50778, 3, 1, bytes16(21), false},                    // CalibrationIlluminant1: D65
  };
  if (!camera_wb) std::erase_if(fields, [](const Field& entry) { return entry.tag == 50728; });
  if (!with_colour_matrix) {
    std::erase_if(fields, [](const Field& entry) {
      return entry.tag == 50721 || entry.tag == 50778;
    });
  }
  if (!colour_fields.empty()) {
    std::erase_if(fields, [](const Field& entry) {
      return entry.tag == 50721 || entry.tag == 50778 || entry.tag == 50728;
    });
    fields.insert(fields.end(), colour_fields.begin(), colour_fields.end());
  }
  fields.insert(fields.end(), extra_fields.begin(), extra_fields.end());
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
  const auto lut_path = std::filesystem::temp_directory_path() /
                        "hyperdr-linearization-fixture.txt";
  const auto lsc_path = std::filesystem::temp_directory_path() /
                        "hyperdr-lens-shading-fixture.txt";
  try {
    write_synthetic_dng(path);

    // Analytic checks on the highlight operation, independent of LibRaw's
    // integer colour transform and the camera-to-P3 matrix below.
    for (unsigned channels : {3U, 4U}) {
      std::array<float, 4> neutral{{60000, 60000, 60000, 60000}};
      hyperdr::codec::blend_highlight_chroma(neutral, channels, 1000);
      for (unsigned c = 0; c < channels; ++c)
        require(neutral[c] == 60000, "neutral highlights became non-finite or lost energy");
      std::array<float, 4> red{{1, 0, 0, 0}};
      hyperdr::codec::blend_highlight_chroma(red, channels, 0.5F);
      float sum = 0;
      for (unsigned c = 0; c < channels; ++c) {
        const float expected = 0.5F / channels + (c == 0 ? 0.5F : 0.0F);
        require(std::abs(red[c] - expected) < 1.0e-7F,
                "highlight chroma blend differs from its analytic value");
        sum += red[c];
      }
      require(std::abs(sum - 1.0F) < 1.0e-7F, "highlight blending changed the channel mean");
      std::array<float, 4> edge{{40000, 20000, 10000, 30000}};
      const auto original_edge = edge;
      hyperdr::codec::blend_highlight_chroma(edge, channels, 65535);
      require(edge == original_edge, "unmodified highlight samples lost precision");
      hyperdr::codec::blend_highlight_chroma(edge, channels, 0.01F);
      for (unsigned c = 0; c < channels; ++c)
        require(std::isfinite(edge[c]) && edge[c] >= 10000 && edge[c] <= 40000,
                "small spatial clip reference overflowed the camera sample range");
    }

    // A 5x5 raster has four reconstruction blocks at block size four. The
    // clipped bottom-right pixel receives three seed neighbours, with total
    // weight five and ratio 1/2. With the neutral prior of weight two its
    // recovered ratio is (5/2 + 2)/(5 + 2) = 9/14. This pins both partial seed
    // blocks and restoration of the final pixel, independently of DNG decoding.
    for (const auto [channels, shading_scale] : {std::pair{3U, 1.0F}, std::pair{4U, 0.25F}}) {
      hyperdr::FloatImage image(5, 5, channels);
      const auto pixel = [&](unsigned i, unsigned c) -> float& { return image.pixels[i * channels + c]; };
      for (unsigned i = 0; i < 25; ++i) {
        pixel(i, 0) = 30000 * shading_scale;
        pixel(i, 1) = 15000 * shading_scale;
        for (unsigned c = 2; c < channels; ++c) pixel(i, c) = 8000 * shading_scale;
      }
      pixel(24, 0) = 60000 * shading_scale;
      pixel(24, 1) = 20000 * shading_scale;
      const std::array<float, 4> base_clip{{65535, 20000, 40000, 40000}};
      hyperdr::codec::reconstruct_highlight_channels(image, 4, base_clip,
          [&](unsigned, unsigned) {
            auto clip = base_clip;
            for (auto& value : clip) value *= shading_scale;
            return clip;
          });
      require(std::abs(pixel(24, 1) - 60000.0F * shading_scale * 9.0F / 14.0F) < 0.01F,
              "partial edge blocks lost the calibrated reconstruction ratio");
      require(pixel(24, 0) == 60000 * shading_scale && pixel(24, 2) == 8000 * shading_scale &&
                  pixel(0, 1) == 15000 * shading_scale && pixel(24, channels - 1) == 8000 * shading_scale,
              "reconstruction changed its reference or an unclipped sample");
    }
    hyperdr::FloatImage zero_reference(1, 1, 3);
    zero_reference.pixels[1] = 1;
    hyperdr::codec::reconstruct_highlight_channels(zero_reference, 4,
        std::array<float, 4>{{65535, 20000, 40000, 40000}},
        [](unsigned, unsigned) { return std::array<float, 4>{{0.01F, 0.001F, 0.01F, 0.01F}}; });
    require(zero_reference.pixels[1] == 1, "zero reference created a non-finite reconstruction ratio");

    // The same corner construction with a seed ratio of 1.6 predicts 60000 *
    // (5*1.6+2)/7 = 85714.2857. Preserve that estimate beyond the integer white.
    hyperdr::FloatImage reconstructed_hdr(5, 5, 3);
    for (unsigned i = 0; i < 25; ++i) {
      reconstructed_hdr.pixels[i * 3] = 30000;
      reconstructed_hdr.pixels[i * 3 + 1] = 48000;
      reconstructed_hdr.pixels[i * 3 + 2] = 8000;
    }
    reconstructed_hdr.at(4, 4, 0) = reconstructed_hdr.at(4, 4, 1) = 60000;
    const std::array<float, 4> hdr_clip{{65535, 60000, 40000, 40000}};
    hyperdr::codec::reconstruct_highlight_channels(reconstructed_hdr, 4, hdr_clip,
        [&](unsigned, unsigned) { return hdr_clip; });
    require(std::abs(reconstructed_hdr.at(4, 4, 1) - 60000.0F * 10.0F / 7.0F) < 0.01F,
            "highlight reconstruction clipped its floating-point HDR estimate");

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

    // 4. Odd DefaultCrop metadata is a request, not a promise about LibRaw's
    //    CFA-aligned delivery. Keep both dimensions and bind consumers to the
    //    actual returned raster.
    write_synthetic_dng(path, 79, 63);
    const auto odd = hyperdr::decode_image(path);
    require(odd.decode.target_width == 63 && odd.decode.target_height == 79,
            "odd requested DefaultCrop was not reported after orientation");
    require(odd.decode.decoded_width == odd.linear_p3.width &&
                odd.decode.decoded_height == odd.linear_p3.height,
            "odd delivered crop does not match LibRaw's returned raster");
    require(odd.decode.default_crop_present &&
                odd.decode.target_dimensions_applied,
            "valid odd DefaultCrop was not applied");

    // 5. The maxcrop guard rejects implausibly small metadata. That fallback is
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

    // Bounds validation must reject a crop that is positive and within the
    // maxcrop ratio but still extends beyond the sensor raster.
    write_synthetic_dng(path, kCropWidth, kCropHeight, kWidth - 8, kCropTop);
    const auto out_of_bounds = hyperdr::decode_image(path);
    // LibRaw may discard an obviously invalid crop before exposing it through
    // raw_inset_crops. If it does expose it, HyperDR must reject it explicitly;
    // either way the visible raster, never the malformed crop, is delivered.
    if (out_of_bounds.decode.default_crop_present) {
      require(out_of_bounds.decode.degraded &&
                  out_of_bounds.decode.degradation_reasons.size() == 1 &&
                  out_of_bounds.decode.degradation_reasons.front() ==
                      "default_crop_out_of_bounds",
              "out-of-bounds DefaultCrop was not rejected explicitly");
      require(!out_of_bounds.decode.target_dimensions_applied,
              "out-of-bounds DefaultCrop claimed to be applied");
    } else {
      require(!out_of_bounds.decode.degraded,
              "LibRaw-discarded DefaultCrop was reported as a different degradation");
    }
    require(out_of_bounds.linear_p3.width == kHeight &&
                out_of_bounds.linear_p3.height == kWidth,
            "out-of-bounds DefaultCrop did not fall back to visible area");

    // RAW-domain callers get the calibrated Bayer raster without the rendered
    // crop/orientation path. Packing must preserve the physical RGGB order and
    // produce the four planes used by neural-network pipelines.
    write_synthetic_dng(path);
    const auto mosaic = hyperdr::decode_raw_mosaic(path);
    require(mosaic.pattern == hyperdr::BayerPattern::RGGB,
            "RAW mosaic CFA was not detected as RGGB");
    require(mosaic.black_level_corrected,
            "RAW mosaic did not report black-level correction");
    require(mosaic.samples.width == kWidth && mosaic.samples.height == kHeight,
            "RAW mosaic unexpectedly applied crop or orientation");
    const auto packed = hyperdr::pack_bayer(mosaic);
    require(packed.width == kWidth / 2 && packed.height == kHeight / 2 &&
                packed.channels == 4,
            "Bayer packing did not produce H/2 x W/2 x 4");
    require(std::fabs(packed.at(0, 0, 0) - mosaic.samples.at(0, 0, 0)) < 1.0e-5F &&
                std::fabs(packed.at(0, 0, 3) - mosaic.samples.at(1, 1, 0)) <
                    1.0e-5F,
            "RGGB packing plane order is incorrect");

    // This piecewise-linear LUT halves low codes while retaining the white
    // endpoint. Black and white must be interpreted through the same LUT.
    hyperdr::write_text_file_atomic(lut_path, "3\n0\n0.25\n1\n", true);
    hyperdr::RawDecodeOptions lut_options;
    lut_options.linearization_lut = lut_path;
    const auto linearized = hyperdr::decode_raw_mosaic(path, lut_options);
    require(linearized.samples.at(0, 0, 0) < mosaic.samples.at(0, 0, 0) * 0.60F,
            "RAW linearization LUT was not applied before normalization");

    hyperdr::write_text_file_atomic(lsc_path, "2 2 1\n2 2 2 2\n", true);
    hyperdr::RawDecodeOptions lsc_options;
    lsc_options.lens_shading_map = lsc_path;
    const auto shaded = hyperdr::decode_raw_mosaic(path, lsc_options);
    require(shaded.samples.at(0, 0, 0) > mosaic.samples.at(0, 0, 0) * 1.9F,
            "RAW lens-shading gain map was not applied before demosaic");

    hyperdr::RawDecodeOptions gain_options;
    gain_options.digital_gain = 2.0F;
    const auto gained = hyperdr::decode_raw_mosaic(path, gain_options);
    require(std::fabs(gained.samples.at(0, 0, 0) -
                      mosaic.samples.at(0, 0, 0) * 2.0F) < 1.0e-4F,
            "RAW digital gain was not retained in normalized mosaic values");

    // A non-zero DNG BlackLevel must be removed before normalization. The
    // first red site contains 512 black code values plus 600 scene values;
    // seeing roughly 600/white proves the subtraction happened in the RAW
    // domain rather than merely dividing the stored code by 65535.
    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 512);
    const auto black_corrected = hyperdr::decode_raw_mosaic(path);
    const float first_red = black_corrected.samples.at(0, 0, 0);
    require(first_red > 0.008F && first_red < 0.011F,
            "DNG BlackLevel was not subtracted before RAW normalization");

    const auto black_lut = hyperdr::decode_raw_mosaic(path, lut_options);
    const float expected_lut = 300.0F / (65535.0F - 256.0F);
    require(std::abs(black_lut.samples.at(0, 0, 0) - expected_lut) < 2.0F / 65535.0F,
            "LUT pixel, black and white levels used different code domains");
    // A purely affine remapping of all codes, including black and white,
    // must leave the normalized sensor signal unchanged.
    hyperdr::write_text_file_atomic(lut_path, "2\n0\n0.5\n", true);
    const auto affine_lut = hyperdr::decode_raw_mosaic(path, lut_options);
    require(std::abs(affine_lut.samples.at(0, 0, 0) - first_red) < 2.0F / 65535.0F,
            "affine LUT changed the calibrated normalized signal");

    // A full-visible-area dark frame remains valid after DefaultCrop, and
    // substitutes its measured bias for the nominal metadata black level.
    const auto dark_path = lsc_path;
    std::string pgm_header = "P5\n96 80\n65535\n";
    std::vector<std::uint8_t> dark_bytes(pgm_header.begin(), pgm_header.end());
    for (unsigned i = 0; i < kWidth * kHeight; ++i) {
      dark_bytes.push_back(1); dark_bytes.push_back(0); // 256 codes, big endian
    }
    hyperdr::write_binary_file_atomic(dark_path, dark_bytes, true);
    hyperdr::RawDecodeOptions dark_options;
    dark_options.dark_frame = dark_path;
    const auto dark_mosaic = hyperdr::decode_raw_mosaic(path, dark_options);
    require(std::abs(dark_mosaic.samples.at(0, 0, 0) - 856.0F / 65023.0F) < 2.0F / 65535.0F,
            "dark calibration did not use the original visible sensor samples");
    const auto before_dark = hyperdr::decode_image(path);
    const auto after_dark = hyperdr::decode_image(path, dark_options);
    require(max_abs_difference(before_dark.linear_p3, after_dark.linear_p3) > 0.001F,
            "DefaultCrop silently disabled the full-visible-area dark frame");
    dark_options.linearization_lut = lut_path;
    const auto dark_lut = hyperdr::decode_raw_mosaic(path, dark_options);
    require(std::abs(dark_lut.samples.at(0, 0, 0) - dark_mosaic.samples.at(0, 0, 0)) < 2.0F / 65535.0F,
            "dark frame and source did not undergo the same affine LUT");
    hyperdr::write_text_file_atomic(dark_path, "P5\n1 1\n65535\n", true);
    bool bad_dark_rejected = false;
    try { static_cast<void>(hyperdr::decode_image(path, dark_options)); }
    catch (const std::invalid_argument&) { bad_dark_rejected = true; }
    require(bad_dark_rejected, "incompatible dark frame was silently ignored");

    // Bad-pixel coordinates also refer to the uncropped visible raster.
    write_synthetic_dng(path);
    const auto before_defect = hyperdr::decode_image(path);
    auto defect_bytes = hyperdr::read_binary_file(path);
    const auto defect_at = defect_bytes.size() - kWidth * kHeight * 2 + (20 * kWidth + 20) * 2;
    defect_bytes[defect_at] = 255; defect_bytes[defect_at + 1] = 255;
    hyperdr::write_binary_file_atomic(path, defect_bytes, true);
    hyperdr::write_text_file_atomic(lsc_path, "20 20 0\n", true);
    hyperdr::RawDecodeOptions defect_options;
    defect_options.bad_pixel_map = lsc_path;
    const auto corrected_defect = hyperdr::decode_image(path, defect_options);
    require(max_abs_difference(before_defect.linear_p3, corrected_defect.linear_p3) < 1.0e-4F,
            "DefaultCrop shifted the bad-pixel coordinates");

    write_synthetic_dng(path);
    hyperdr::write_text_file_atomic(lsc_path, "2 2 1\n2 2 2 2\n", true);
    const auto rgb_lsc = hyperdr::decode_image(path, lsc_options);
    const auto rgb_gain = hyperdr::decode_image(path, gain_options);
    require(max_abs_difference(rgb_lsc.linear_p3, rgb_gain.linear_p3) < 1.0e-4F,
            "uniform LSC lost highlights before the float HDR domain");
    lsc_options.half_size = gain_options.half_size = true;
    require(max_abs_difference(hyperdr::decode_image(path, lsc_options).linear_p3,
                               hyperdr::decode_image(path, gain_options).linear_p3) < 1.0e-4F,
            "half-size LSC lost highlight headroom");
    lsc_options.half_size = gain_options.half_size = false;

    // The blown disc lies inside a gain=1 plateau, while the same crop also
    // contains gain=4 at its left edge. A global max must not suppress recovery
    // inside the plateau just because another region needs more correction.
    std::string plateau_map = "96 80 1\n";
    for (unsigned y = 0; y < kHeight; ++y)
      for (unsigned x = 0; x < kWidth; ++x)
        plateau_map += x < 20 ? "4 " : "1 ";
    hyperdr::write_text_file_atomic(lsc_path, plateau_map, true);
    for (const auto mode : {hyperdr::HighlightRecovery::Blend,
                            hyperdr::HighlightRecovery::Reconstruct}) {
      for (const bool half : {false, true}) {
        hyperdr::RawDecodeOptions reference_options;
        reference_options.half_size = half;
        reference_options.highlight_recovery = mode;
        auto calibrated_options = reference_options;
        calibrated_options.lens_shading_map = lsc_path;
        const auto expected = hyperdr::decode_image(path, reference_options);
        const auto actual = hyperdr::decode_image(path, calibrated_options);
        const unsigned divisor = half ? 2 : 1;
        float error = 0;
        // Sensor (60,32), away from both the calibration and demosaic edges;
        // the DNG fixture rotates the cropped raster 90 degrees clockwise.
        for (unsigned y = 26 / divisor; y < 38 / divisor; ++y)
          for (unsigned x = 54 / divisor; x < 66 / divisor; ++x)
            for (unsigned c = 0; c < 3; ++c) {
              const unsigned ox = (kCropTop + kCropHeight) / divisor - 1 - y;
              const unsigned oy = x - kCropLeft / divisor;
              error = std::max(error, std::abs(expected.linear_p3.at(ox, oy, c) -
                                              actual.linear_p3.at(ox, oy, c)));
            }
        std::cout << "spatial shading " << (mode == hyperdr::HighlightRecovery::Blend ? "Blend" : "Reconstruct")
                  << " plateau error: " << error << '\n';
        require(error < 0.002F, "spatial shading suppressed highlight recovery");
      }
    }

    // A common calibration gain is exposure, including gains below one.
    // It must not change which samples LibRaw considers saturated.
    for (const auto mode : {hyperdr::HighlightRecovery::Blend,
                            hyperdr::HighlightRecovery::Reconstruct}) {
      for (const bool half : {false, true}) {
        hyperdr::RawDecodeOptions reference_options;
        reference_options.highlight_recovery = mode;
        reference_options.half_size = half;
        reference_options.digital_gain = 0.5F;
        auto calibrated_options = reference_options;
        calibrated_options.digital_gain = 1.0F;
        calibrated_options.lens_shading_map = lsc_path;
        hyperdr::write_text_file_atomic(lsc_path, "1 1 1\n0.5\n", true);
        const auto expected = hyperdr::decode_image(path, reference_options);
        const auto actual = hyperdr::decode_image(path, calibrated_options);
        const float attenuation_error = max_abs_difference(expected.linear_p3, actual.linear_p3);
        std::cout << "constant shading highlight error: " << attenuation_error << '\n';
        require(attenuation_error < 1.0e-5F,
                "constant shading attenuation changed highlight recovery");

        // Only an unused sensor corner differs. Every interpolated gain in
        // DefaultCrop remains exactly one, for all four CFA channels.
        std::string outside_map = "96 80 4\n";
        for (unsigned i = 0; i < kWidth * kHeight; ++i)
          outside_map += i == 0 ? "4 4 4 4\n" : "1 1 1 1\n";
        hyperdr::write_text_file_atomic(lsc_path, outside_map, true);
        reference_options.digital_gain = 1.0F;
        require(max_abs_difference(hyperdr::decode_image(path, reference_options).linear_p3,
                                   hyperdr::decode_image(path, calibrated_options).linear_p3) < 1.0e-5F,
                "shading outside DefaultCrop changed visible highlights");
      }
    }

    // The crop remains nonconstant, so it cannot take the common-gain path.
    // An unused corner must not set its integer normalization precision.
    bool crop_range_preserved = true;
    for (const bool half : {false, true}) {
      hyperdr::RawDecodeOptions range_options;
      range_options.half_size = half;
      range_options.highlight_recovery = hyperdr::HighlightRecovery::Unclip;
      range_options.lens_shading_map = lsc_path;
      const auto range_map = [](bool outside_peak) {
        std::string text = "96 80 1\n";
        for (unsigned y = 0; y < kHeight; ++y)
          for (unsigned x = 0; x < kWidth; ++x)
            text += std::to_string(outside_peak && x == 0 && y == 0
                ? 64.0F : 1.0F + static_cast<float>(x) / (kWidth - 1)) + " ";
        return text;
      };
      hyperdr::write_text_file_atomic(lsc_path, range_map(false), true);
      const auto expected = hyperdr::decode_image(path, range_options);
      hyperdr::write_text_file_atomic(lsc_path, range_map(true), true);
      const auto actual = hyperdr::decode_image(path, range_options);
      const float error = max_abs_difference(expected.linear_p3, actual.linear_p3);
      std::cout << "nonconstant crop shading range error (half=" << half << "): " << error << '\n';
      crop_range_preserved = crop_range_preserved && error < 1.0e-6F;
    }
    require(crop_range_preserved, "unused shading vertex reduced nonconstant crop precision");

    // Mosaic consumers have no demosaic or highlight stage. Applying a small
    // gain in float must preserve even the darkest stored sensor sample.
    hyperdr::write_text_file_atomic(lsc_path, "2 2 1\n0.001 64 0.001 64\n", true);
    lsc_options.half_size = false;
    const auto precise_shading = hyperdr::decode_raw_mosaic(path, lsc_options);
    require(std::abs(precise_shading.samples.at(0, 0, 0) -
                     mosaic.samples.at(0, 0, 0) * 0.001F) < 1.0e-8F,
            "integer shading normalization erased a nonzero sensor sample");
    hyperdr::write_text_file_atomic(lsc_path, "1 1 4\n0.5 1 2 4\n", true);
    const auto four_plane_shading = hyperdr::decode_raw_mosaic(path, lsc_options);
    const float site_gain[2][2] = {{0.5F, 1.0F}, {4.0F, 2.0F}};
    for (unsigned y = 0; y < 2; ++y)
      for (unsigned x = 0; x < 2; ++x)
        require(std::abs(four_plane_shading.samples.at(x, y, 0) -
                         mosaic.samples.at(x, y, 0) * site_gain[y][x]) < 1.0e-7F,
                "float mosaic shading mixed the two green calibration planes");

    // A spatial calibration has the same sensor coordinates with and without
    // DefaultCrop. Exclude demosaic borders when comparing the two renders.
    hyperdr::write_text_file_atomic(lsc_path, "2 2 1\n1 2 1 2\n", true);
    for (const bool half : {false, true}) {
      lsc_options.half_size = half;
      const unsigned divisor = half ? 2 : 1;
      write_synthetic_dng(path);
      const auto crop_lsc = hyperdr::decode_image(path, lsc_options);
      write_synthetic_dng(path, kWidth, kHeight, 0, 0);
      const auto full_lsc = hyperdr::decode_image(path, lsc_options);
      float crop_error = 0.0F;
      for (unsigned y = 8; y + 8 < crop_lsc.linear_p3.height; ++y)
        for (unsigned x = 8; x + 8 < crop_lsc.linear_p3.width; ++x)
          for (unsigned c = 0; c < 3; ++c)
            crop_error = std::max(crop_error, std::abs(crop_lsc.linear_p3.at(x,y,c) -
                full_lsc.linear_p3.at(x + (kHeight - kCropTop - kCropHeight) / divisor,
                                     y + kCropLeft / divisor,c)));
      require(crop_error < 0.005F, "DefaultCrop shifted the lens-shading calibration grid");
    }

    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, false);
    hyperdr::RawDecodeOptions clip_options;
    clip_options.highlight_recovery = hyperdr::HighlightRecovery::Clip;
    const auto fallback_clip = hyperdr::decode_image(path, clip_options);
    const auto fallback_blend = hyperdr::decode_image(path);
    require(fallback_clip.raw_white_balance == "auto" &&
                fallback_blend.raw_white_balance == "auto",
            "missing camera WB was not reported as an automatic fallback");
    require(std::abs(std::log2(median_luminance(fallback_clip.linear_p3) /
                              median_luminance(fallback_blend.linear_p3))) < 0.05F,
            "WB fallback changed whole-image exposure between highlight modes");

    // Through this fixture's diagonal ColorMatrix, a field lit only at the red
    // sites is pure CIE X: an imaginary colour with zero luminance and -0.39
    // AP1 green relative to red. Unclamped, it reaches the renderer as black,
    // which is what narrow-band blue lights did in real frames. Clamped at
    // ProPhoto's boundary it keeps -0.06 AP1 green and P3 luminance 0.16 of
    // its P3 red; gamut compression brings it inside AP1 with 0.19.
    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false,
                        true, {20000, 0, 0});
    const auto red = hyperdr::decode_image(path);
    require(red.raw_color_matrix == "embedded",
            "a DNG ColorMatrix was not reported as the file's own matrix");
    const auto centre = [](const hyperdr::FloatImage& image) {
      return std::array<float, 3>{image.at(image.width / 2, image.height / 2, 0),
                                  image.at(image.width / 2, image.height / 2, 1),
                                  image.at(image.width / 2, image.height / 2, 2)};
    };
    const auto red_p3 = centre(red.linear_p3);
    const auto red_ap1 = hyperdr::linear_p3_to_ap1_d65(red_p3[0], red_p3[1], red_p3[2]);
    require(red_ap1[0] > 0.0F && red_ap1[1] > -1.0e-4F * red_ap1[0] &&
                red_ap1[2] > -1.0e-4F * red_ap1[0],
            "a colour outside the spectral locus was left outside AP1 by RAW decode (AP1 " +
                std::to_string(red_ap1[0]) + ", " + std::to_string(red_ap1[1]) + ", " +
                std::to_string(red_ap1[2]) + ")");
    require(hyperdr::p3_luminance(red_p3[0], red_p3[1], red_p3[2]) > 0.1F * red_p3[0],
            "a colour outside the spectral locus left RAW decode without visible luminance");
    // The matrix is applied in float, so headroom above LibRaw's 16-bit output
    // survives. Clip highlight handling saturates the red sites at white, and
    // white camera red is 2.18 in P3 red; LibRaw's output capped its ProPhoto
    // red at 1.0 (1.63 in P3).
    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false,
                        true, {60000, 0, 0});
    const auto bright = hyperdr::decode_image(path, clip_options);
    const float bright_red = centre(bright.linear_p3)[0];
    require(bright_red > 2.0F && bright_red < 2.3F,
            "RAW highlight headroom was clipped at LibRaw's 16-bit ceiling (P3 red " +
                std::to_string(bright_red) + ")");
    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false,
                        false, {20000, 0, 0});
    const auto uncalibrated = hyperdr::decode_image(path);
    const auto& uncalibrated_reasons = uncalibrated.decode.degradation_reasons;
    require(uncalibrated.raw_color_matrix == "none" && uncalibrated.decode.degraded &&
                std::find(uncalibrated_reasons.begin(), uncalibrated_reasons.end(),
                          "no_camera_matrix") != uncalibrated_reasons.end(),
            "a RAW without any camera matrix was not reported as a degraded decode");

    // A DNG is decoded with its own colour model: both calibrations
    // interpolated at the as-shot white, not LibRaw's D65 ColorMatrix alone.
    // The calibrations are a Ricoh GR IV's (standard light A and D65, as-shot
    // white near 4600 K), where the two give colours about 0.01 apart in
    // chromaticity. A second file adds ForwardMatrices, CameraCalibrations
    // and AnalogBalance, so every field LibRaw exposes is read in its place.
    {
      hyperdr::DngColorProfile profile;
      profile.calibrations[0].illuminant = 17;
      profile.calibrations[0].color_matrix = hyperdr::Matrix3d{
          {{0.698959, -0.287201, -0.031876}, {-0.380997, 0.997040, 0.446777},
           {-0.011490, 0.036133, 0.737518}}};
      profile.calibrations[1].illuminant = 21;
      profile.calibrations[1].color_matrix = hyperdr::Matrix3d{
          {{0.642670, -0.148453, -0.081421}, {-0.461395, 1.272781, 0.206543},
           {-0.067871, 0.151535, 0.603012}}};
      const std::array<double, 3> neutral{0.4136, 1.0, 0.5614};
      auto full = profile;
      full.calibrations[0].forward_matrix = hyperdr::Matrix3d{
          {{0.702589, 0.153334, 0.108373}, {0.449611, 1.094298, -0.543910},
           {0.004547, -0.052018, 0.872576}}};
      full.calibrations[1].forward_matrix = hyperdr::Matrix3d{
          {{0.825411, 0.099922, 0.038963}, {0.505329, 0.681835, -0.187164},
           {0.015447, -0.097989, 0.907646}}};
      full.calibrations[0].camera_calibration =
          hyperdr::Matrix3d{{{1.02, 0.01, 0.0}, {0.0, 0.98, 0.0}, {0.0, 0.005, 1.01}}};
      full.calibrations[1].camera_calibration =
          hyperdr::Matrix3d{{{1.01, 0.0, 0.0}, {0.004, 1.0, 0.0}, {0.0, 0.0, 0.99}}};
      full.analog_balance = {1.05, 1.0, 0.97};

      const auto tags = [&](const hyperdr::DngColorProfile& source) {
        std::vector<Field> out{
            {50721, 10, 9, srational_matrix(*source.calibrations[0].color_matrix), false},
            {50722, 10, 9, srational_matrix(*source.calibrations[1].color_matrix), false},
            {50727, 5, 3, rational_vector(source.analog_balance), false},
            {50728, 5, 3, rational_vector(neutral), false},
            {50778, 3, 1, bytes16(source.calibrations[0].illuminant), false},
            {50779, 3, 1, bytes16(source.calibrations[1].illuminant), false},
        };
        const std::array<std::uint16_t, 2> calibration_tags{50723, 50724};
        const std::array<std::uint16_t, 2> forward_tags{50964, 50965};
        for (std::size_t k = 0; k < 2; ++k) {
          const auto& calibration = source.calibrations[k];
          if (calibration.camera_calibration) {
            out.push_back({calibration_tags[k], 10, 9,
                           srational_matrix(*calibration.camera_calibration), false});
          }
          if (calibration.forward_matrix) {
            out.push_back({forward_tags[k], 10, 9, srational_matrix(*calibration.forward_matrix), false});
          }
        }
        return out;
      };
      const auto chromaticity = [](const std::array<double, 3>& rgb) {
        const double sum = rgb[0] + rgb[1] + rgb[2];
        return std::array<double, 3>{rgb[0] / sum, rgb[1] / sum, rgb[2] / sum};
      };
      const auto predicted = [&](const hyperdr::Matrix3d& matrix, const std::array<std::uint16_t, 3>& level) {
        std::array<double, 3> p3{};
        for (std::size_t i = 0; i < 3; ++i) {
          for (std::size_t c = 0; c < 3; ++c) p3[i] += matrix[i][c] * level[c] / neutral[c];
        }
        return p3;
      };
      const auto d65_only = *hyperdr::dng_camera_to_linear_p3(
          [&] {
            hyperdr::DngColorProfile one;
            one.calibrations[0] = profile.calibrations[1];
            return one;
          }(),
          neutral);
      for (const auto* variant : {&profile, &full}) {
        const auto expected_matrix = hyperdr::dng_camera_to_linear_p3(*variant, neutral);
        require(expected_matrix.has_value(), "the DNG colour fixture must be a valid profile");
        for (const std::array<std::uint16_t, 3>& level :
             {std::array<std::uint16_t, 3>{12000, 20000, 6000},
              std::array<std::uint16_t, 3>{6000, 24000, 28000}}) {
          write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false, true,
                              level, tags(*variant));
          const auto dng = hyperdr::decode_image(path, clip_options);
          require(dng.raw_color_matrix == "embedded",
                  "a DNG with two calibrations was not reported as using its own matrix");
          const auto pixel = centre(dng.linear_p3);
          const auto expected = predicted(*expected_matrix, level);
          require(*std::min_element(expected.begin(), expected.end()) >
                      0.05 * *std::max_element(expected.begin(), expected.end()),
                  "the DNG colour fixture must stay inside P3, clear of gamut compression");
          const auto got = chromaticity({pixel[0], pixel[1], pixel[2]});
          const auto want = chromaticity(expected);
          const auto other = chromaticity(predicted(d65_only, level));
          double error = 0.0;
          double separation = 0.0;
          for (std::size_t i = 0; i < 3; ++i) {
            error = std::max(error, std::abs(got[i] - want[i]));
            separation = std::max(separation, std::abs(want[i] - other[i]));
          }
          require(error < 1.0e-3,
                  "a DNG was not decoded with its own colour model (chromaticity off by " +
                      std::to_string(error) + ")");
          if (variant == &profile) {
            require(separation > 5.0e-3,
                    "the DNG colour fixture cannot tell its interpolated matrix from the D65 one");
          }
        }
      }

      // CameraCalibration belongs to a reference camera identified by its
      // signature. A profile with a different signature must use identity
      // calibration, including when just one of the signatures is absent.
      // The cases above already cover both absent (the empty strings match).
      const std::array<std::uint16_t, 3> signature_level{12000, 20000, 6000};
      auto without_calibration = full;
      for (auto& calibration : without_calibration.calibrations) {
        calibration.camera_calibration.reset();
      }
      const auto decode_profile = [&](const hyperdr::DngColorProfile& source,
                                       const std::vector<Field>& signatures) {
        write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0,
                            true, false, true, signature_level, tags(source), signatures);
        return hyperdr::decode_image(path, clip_options).linear_p3;
      };
      const auto calibrated = decode_profile(full, {});
      const auto uncalibrated = decode_profile(without_calibration, {});
      require(max_abs_difference(calibrated, uncalibrated) > 1.0e-3F,
              "the calibration-signature fixture must distinguish its camera calibration");
      const auto signature_tag = [](std::uint16_t tag, const char* text, std::uint16_t type) {
        std::vector<std::uint8_t> value(text, text + std::strlen(text) + 1);
        return Field{tag, type, static_cast<std::uint32_t>(value.size()), value, false};
      };
      const auto camera_signature = signature_tag(50931, "camera-reference", 2);
      const auto same_profile = signature_tag(50932, "camera-reference", 1);
      const auto other_profile = signature_tag(50932, "other-reference", 2);
      require(max_abs_difference(decode_profile(full, {camera_signature, same_profile}), calibrated) < 1.0e-6F,
              "matching DNG calibration signatures must apply CameraCalibration");
      for (const auto& signatures : {std::vector<Field>{camera_signature, other_profile},
                                     std::vector<Field>{camera_signature},
                                     std::vector<Field>{same_profile}}) {
        require(max_abs_difference(decode_profile(full, signatures), uncalibrated) < 1.0e-6F,
                "nonmatching DNG calibration signatures must use identity CameraCalibration");
      }
    }

    // A DNG's opcode lists are applied. OpcodeList2's GainMap here brightens
    // the sensor from 1x at the top row to 2x at the bottom; decoded against
    // the same file without it, every pixel must come out brighter by the
    // gain at its sensor row. The fixture's 90-degree orientation turns
    // sensor rows into output columns, counted from the bottom row.
    {
      const auto opcode_tag = [](std::uint16_t tag, const std::vector<std::uint8_t>& list) {
        return Field{tag, 7, static_cast<std::uint32_t>(list.size()), list, false};
      };
      std::vector<std::uint8_t> ramp;
      for (const std::uint32_t value : {0U, 0U, kHeight, kWidth, 0U, 1U, 1U, 1U, 2U, 1U}) put_be32(ramp, value);
      put_be64(ramp, 1.0);  // spacing, rows
      put_be64(ramp, 1.0);  // spacing, columns
      put_be64(ramp, 0.0);  // origin, rows
      put_be64(ramp, 0.0);  // origin, columns
      put_be32(ramp, 1);    // map planes
      for (const float gain : {1.0F, 2.0F}) {
        std::uint32_t bits = 0;
        std::memcpy(&bits, &gain, sizeof(bits));
        put_be32(ramp, bits);
      }
      const std::array<std::uint16_t, 3> flat{6000, 6000, 6000};
      write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false, true, flat);
      const auto plain = hyperdr::decode_image(path, clip_options);
      write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false, true, flat, {},
                          {opcode_tag(51009, opcode_list({opcode(9, 0, ramp)}))});
      const auto ramped = hyperdr::decode_image(path, clip_options);
      require(!ramped.decode.degraded, "a GainMap the decoder applies must not degrade the decode");
      const auto y = ramped.linear_p3.height / 2;
      for (std::uint32_t x = 2; x + 2 < ramped.linear_p3.width; x += 6) {
        const double row = kCropTop + kCropHeight - 1.0 - x;
        const double expected = 1.0 + (row + 0.5) / kHeight;
        const double ratio = ramped.linear_p3.at(x, y, 1) / plain.linear_p3.at(x, y, 1);
        require(std::abs(ratio / expected - 1.0) < 0.01,
                "OpcodeList2 GainMap was not applied at its sensor row (output column " + std::to_string(x) +
                    ": " + std::to_string(ratio) + ", expected " + std::to_string(expected) + ")");
      }

      // OpcodeList1: dead pixels stored as 0 are fixed from their neighbours.
      const auto dead = [&](bool with_opcode) {
        std::vector<Field> extra;
        if (with_opcode) {
          std::vector<std::uint8_t> parameters;
          put_be32(parameters, 0);  // constant
          put_be32(parameters, 1);  // Bayer phase: red at the top left
          extra.push_back(opcode_tag(51008, opcode_list({opcode(4, 0, parameters)})));
        }
        write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false, true, flat, {},
                            extra);
        auto bytes = hyperdr::read_binary_file(path);
        for (const auto& [sx, sy] : {std::pair{40U, 40U}, std::pair{41U, 40U}, std::pair{47U, 33U}}) {
          const auto at = bytes.size() - kWidth * kHeight * 2 + (sy * kWidth + sx) * 2;
          bytes[at] = 0;
          bytes[at + 1] = 0;
        }
        hyperdr::write_binary_file_atomic(path, bytes, true);
        return hyperdr::decode_image(path, clip_options);
      };
      require(max_abs_difference(dead(true).linear_p3, plain.linear_p3) < 1.0e-4F,
              "OpcodeList1 FixBadPixelsConstant left dead pixels in the decode");
      require(max_abs_difference(dead(false).linear_p3, plain.linear_p3) > 0.01F,
              "the dead-pixel fixture must show its defects without the opcode");

      // A required opcode this decoder does not apply is reported; an optional
      // one, or a list that does not parse, too, each by its own reason.
      const auto reasons = [&](const std::vector<Field>& extra) {
        write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, false, true, flat, {},
                            extra);
        return hyperdr::decode_image(path, clip_options).decode.degradation_reasons;
      };
      const auto has = [](const std::vector<std::string>& list, const char* reason) {
        return std::find(list.begin(), list.end(), reason) != list.end();
      };
      const std::vector<std::uint8_t> warp_parameters{0, 0, 0, 1};
      require(has(reasons({opcode_tag(51022, opcode_list({opcode(1, 0, warp_parameters)}))}),
                  "dng_opcode_unsupported"),
              "a required opcode that was not applied must degrade the decode");
      require(reasons({opcode_tag(51022, opcode_list({opcode(1, 1, warp_parameters)}))}).empty(),
              "an optional opcode that was not applied must not degrade the decode");
      auto cut = opcode_list({opcode(9, 0, ramp)});
      cut.resize(cut.size() - 5);
      require(has(reasons({opcode_tag(51009, cut)}), "dng_opcode_list_malformed"),
              "a malformed opcode list must degrade the decode");
    }

    write_synthetic_dng(path, kCropWidth, kCropHeight, kCropLeft, kCropTop, 0, true, true);
    bool xtrans_rejected = false;
    try { static_cast<void>(hyperdr::decode_raw_mosaic(path)); }
    catch (const std::invalid_argument&) { xtrans_rejected = true; }
    require(xtrans_rejected, "6x6 X-Trans was silently packed as a 2x2 Bayer CFA");

    std::filesystem::remove(path);
    std::filesystem::remove(lut_path);
    std::filesystem::remove(lsc_path);
    std::cout << "RAW highlight recovery test passed (four distinct decodes, "
                 "stable exposure, oriented DefaultCrop)\n";
    return 0;
  } catch (const std::exception& e) {
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    std::filesystem::remove(lut_path, ignored);
    std::filesystem::remove(lsc_path, ignored);
    std::cerr << "RAW highlight recovery test failure: " << e.what() << '\n';
    return 1;
  }
}

#include "hyperdr/gainmap/external.hpp"

#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/rational.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

constexpr std::size_t kMaxGainPixels = 16U * 1024U * 1024U;

const json::Value& required_member(const json::Value& object,
                                   std::string_view key) {
  const auto* value = object.find(key);
  if (value == nullptr) {
    throw std::invalid_argument("external gain report is missing " +
                                std::string(key));
  }
  return *value;
}

std::uint32_t positive_dimension(const json::Value& value,
                                 std::string_view name) {
  if (!value.is_number() || !std::isfinite(value.number()) ||
      value.number() < 1.0 || value.number() > 131072.0 ||
      std::floor(value.number()) != value.number()) {
    throw std::invalid_argument("external gain report has invalid " +
                                std::string(name));
  }
  return static_cast<std::uint32_t>(value.number());
}

float finite_number(const json::Value& value, std::string_view name) {
  if (!value.is_number() || !std::isfinite(value.number())) {
    throw std::invalid_argument("external gain report has invalid " +
                                std::string(name));
  }
  return static_cast<float>(value.number());
}

void require_string(const json::Value& object, std::string_view key,
                    std::string_view expected) {
  const auto& value = required_member(object, key);
  if (!value.is_string() || value.string() != expected) {
    throw std::invalid_argument("external gain report has invalid " +
                                std::string(key));
  }
}

std::vector<float> decoded_stops(const FloatImage& gain, float max_stops) {
  std::vector<float> values;
  values.reserve(gain.pixels.size());
  for (const float code : gain.pixels) {
    values.push_back(std::clamp(code, 0.0F, 1.0F) * max_stops);
  }
  return values;
}

Rational rational_member(const json::Value& object, std::string_view key) {
  const auto& value = required_member(object, key);
  if (!value.is_object()) {
    throw std::invalid_argument("external gain metadata has invalid " + std::string(key));
  }
  const auto& numerator = required_member(value, "numerator");
  const auto& denominator = required_member(value, "denominator");
  if (!numerator.is_number() || !denominator.is_number() ||
      !std::isfinite(numerator.number()) || !std::isfinite(denominator.number()) ||
      std::floor(numerator.number()) != numerator.number() ||
      std::floor(denominator.number()) != denominator.number() ||
      denominator.number() < 1.0 || denominator.number() > 4294967295.0 ||
      numerator.number() < -2147483648.0 || numerator.number() > 2147483647.0) {
    throw std::invalid_argument("external gain metadata has invalid rational " + std::string(key));
  }
  return {static_cast<std::int32_t>(numerator.number()),
          static_cast<std::uint32_t>(denominator.number())};
}

GainMapMetadata read_v2_metadata(const json::Value& document) {
  const auto& value = required_member(document, "gain_metadata");
  if (!value.is_object()) throw std::invalid_argument("v2 sidecar has invalid gain_metadata");
  GainMapMetadata metadata;
  if (const auto* item = value.find("minimum_version"); item && item->is_number()) {
    metadata.minimum_version = static_cast<std::uint16_t>(item->number());
  }
  if (const auto* item = value.find("writer_version"); item && item->is_number()) {
    metadata.writer_version = static_cast<std::uint16_t>(item->number());
  }
  if (const auto* item = value.find("flags"); item && item->is_number()) {
    metadata.flags = static_cast<std::uint8_t>(item->number());
  }
  if (const auto* item = value.find("use_base_color_space"); item && item->is_bool()) {
    metadata.use_base_color_space = item->boolean();
  }
  if (const auto* item = value.find("backward_direction"); item && item->is_bool()) {
    metadata.backward_direction = item->boolean();
  }
  if (const auto* item = value.find("common_denominator"); item && item->is_bool()) {
    metadata.common_denominator = item->boolean();
  }
  metadata.base_headroom = rational_member(value, "base_headroom");
  metadata.alternate_headroom = rational_member(value, "alternate_headroom");
  metadata.gain_min = rational_member(value, "gain_min");
  metadata.gain_max = rational_member(value, "gain_max");
  metadata.gamma = rational_member(value, "gamma");
  metadata.base_offset = rational_member(value, "base_offset");
  metadata.alternate_offset = rational_member(value, "alternate_offset");
  if (metadata.minimum_version != 0 || metadata.writer_version != 0 ||
      metadata.backward_direction || metadata.flags & 0x80U ||
      metadata.flags & ~(0xCCU)) {
    throw std::invalid_argument("v2 sidecar declares unsupported ISO metadata");
  }
  if (metadata.use_base_color_space != ((metadata.flags & 0x40U) != 0) ||
      metadata.common_denominator != ((metadata.flags & 0x08U) != 0) ||
      metadata.backward_direction != ((metadata.flags & 0x04U) != 0)) {
    throw std::invalid_argument("v2 sidecar metadata flags conflict with their fields");
  }
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alternate_headroom = rational_value(metadata.alternate_headroom);
  const float gain_min = rational_value(metadata.gain_min);
  const float gain_max = rational_value(metadata.gain_max);
  const float gamma = rational_value(metadata.gamma);
  const float base_offset = rational_value(metadata.base_offset);
  const float alternate_offset = rational_value(metadata.alternate_offset);
  if (!std::isfinite(base_headroom) || !std::isfinite(alternate_headroom) ||
      !std::isfinite(gain_min) || !std::isfinite(gain_max) ||
      !std::isfinite(gamma) || !std::isfinite(base_offset) ||
      !std::isfinite(alternate_offset) || base_headroom < 0.0F ||
      alternate_headroom < 0.0F || gain_max < gain_min ||
      std::abs(gain_min) > 64.0F || std::abs(gain_max) > 64.0F ||
      !(gamma > 0.0F) || gamma > 64.0F || std::abs(base_offset) > 64.0F ||
      std::abs(alternate_offset) > 64.0F) {
    throw std::invalid_argument("v2 sidecar declares invalid gain metadata");
  }
  if (std::abs(gain_max - alternate_headroom) > 1.0e-6F) {
    throw std::invalid_argument("v2 sidecar gain_max conflicts with alternate_headroom");
  }
  if (metadata.common_denominator) {
    const auto denominator = metadata.base_headroom.denominator;
    for (const Rational* rational : {&metadata.alternate_headroom, &metadata.gain_min,
                                     &metadata.gain_max, &metadata.gamma,
                                     &metadata.base_offset, &metadata.alternate_offset}) {
      if (rational->denominator != denominator) {
        throw std::invalid_argument("v2 common-denominator metadata is inconsistent");
      }
    }
  }
  return metadata;
}

}  // namespace

ExternalGainMap read_external_gain_map(const std::filesystem::path& gain_path,
                                       const std::filesystem::path& report_path,
                                       bool allow_legacy_external_gain) {
  if (gain_path.empty() || report_path.empty()) {
    throw std::invalid_argument(
        "external gain requires both --external-gain and --external-gain-report");
  }

  const auto report_bytes = read_binary_file(report_path);
  const auto document = json::parse(std::string_view(
      reinterpret_cast<const char*>(report_bytes.data()), report_bytes.size()));
  if (!document.is_object()) {
    throw std::invalid_argument("external gain report must be a JSON object");
  }

  const auto& grid = required_member(document, "gain_grid_size");
  if (!grid.is_array() || grid.array().size() != 2) {
    throw std::invalid_argument("external gain report has invalid gain_grid_size");
  }
  const auto width = positive_dimension(grid.array()[0], "gain_grid_size width");
  const auto height = positive_dimension(grid.array()[1], "gain_grid_size height");
  const auto pixel_count = static_cast<std::size_t>(width) * height;
  if (pixel_count > kMaxGainPixels) {
    throw std::invalid_argument("external gain grid is too large");
  }

  const auto& file = required_member(document, "gain_file");
  if (!file.is_object()) {
    throw std::invalid_argument("external gain report has invalid gain_file");
  }
  require_string(file, "format", "raw_float32_with_required_json_sidecar");
  require_string(file, "endianness", "little");
  const auto& scale_value = required_member(file, "scale");
  if (!scale_value.is_string() ||
      (scale_value.string() != "normalized_log2_gain_0_to_1" &&
       scale_value.string() != "signed_log2_gain")) {
    throw std::invalid_argument("external gain report has unsupported scale");
  }
  const bool canonical_log2 = scale_value.string() == "signed_log2_gain";
  const auto* contract = document.find("label_contract_id");
  const bool v2 = canonical_log2 && contract && contract->is_string() &&
                  contract->string() == "hyperdr.apple-gain-label/v2";
  if (canonical_log2 && !v2) {
    throw std::invalid_argument("signed canonical gain requires label contract v2");
  }
  if (!canonical_log2 && !allow_legacy_external_gain) {
    throw std::invalid_argument(
        "v1 normalized external gain is disabled; pass --allow-legacy-external-gain");
  }
  const auto file_width = positive_dimension(required_member(file, "width"), "gain_file width");
  const auto file_height = positive_dimension(required_member(file, "height"), "gain_file height");
  if (file_width != width || file_height != height) {
    throw std::invalid_argument("external gain report dimensions disagree");
  }

  const auto& byte_length_value = required_member(file, "byte_length");
  if (!byte_length_value.is_number() || !std::isfinite(byte_length_value.number()) ||
      byte_length_value.number() < 0.0 ||
      byte_length_value.number() != static_cast<double>(pixel_count * sizeof(float))) {
    throw std::invalid_argument("external gain report has invalid byte_length");
  }

  float max_stops = 0.0F;
  GainMapMetadata metadata;
  if (v2) {
    metadata = read_v2_metadata(document);
    max_stops = rational_value(metadata.gain_max);
    if (max_stops < -64.0F || max_stops > 64.0F) {
      throw std::invalid_argument("v2 external gain range is outside the safety bound");
    }
  } else {
    max_stops = finite_number(required_member(document, "metadata_gain_max_stops"),
                               "metadata_gain_max_stops");
    if (max_stops < 0.0F || max_stops > 4.0F) {
      throw std::invalid_argument("external gain max stops must be in [0, 4]");
    }
  }

  const auto bytes = read_binary_file(gain_path);
  const auto expected_bytes = pixel_count * sizeof(float);
  if (bytes.size() != expected_bytes) {
    throw std::invalid_argument("external gain byte length does not match its report");
  }
  if (const auto* hash = file.find("sha256"); hash && hash->is_string() &&
      sha256_file_hex(gain_path) != hash->string()) {
    throw std::invalid_argument("external gain hash does not match its report");
  }

  ExternalGainMap result;
  result.gain_map = FloatImage(width, height, 1);
  result.max_stops = max_stops;
  result.metadata = metadata;
  result.canonical_log2 = v2;
  result.legacy_schema = !v2;
  for (std::size_t index = 0; index < pixel_count; ++index) {
    const auto offset = index * sizeof(float);
    const auto bits = static_cast<std::uint32_t>(bytes[offset]) |
                      (static_cast<std::uint32_t>(bytes[offset + 1]) << 8U) |
                      (static_cast<std::uint32_t>(bytes[offset + 2]) << 16U) |
                      (static_cast<std::uint32_t>(bytes[offset + 3]) << 24U);
    const float value = std::bit_cast<float>(bits);
    if (!std::isfinite(value) ||
        (!canonical_log2 && (value < 0.0F || value > 1.0F)) ||
        (canonical_log2 && (value < -64.0F || value > 64.0F))) {
      throw std::invalid_argument(canonical_log2
                                      ? "external canonical gain is outside [-64, 64]"
                                      : "external gain contains a value outside [0, 1]");
    }
    result.gain_map.pixels[index] = value;
  }
  return result;
}

void apply_external_gain_map(GainMapResult& result, ExternalGainMap external) {
  const bool canonical = external.canonical_log2;
  const float max_stops = canonical
                              ? rational_value(external.metadata.gain_max)
                              : external.max_stops;
  std::vector<float> stops;
  stops.reserve(external.gain_map.pixels.size());
  if (canonical) {
    result.metadata = external.metadata;
    const float min_gain = rational_value(result.metadata.gain_min);
    const float max_gain = rational_value(result.metadata.gain_max);
    const float gamma = std::max(rational_value(result.metadata.gamma), 1.0e-6F);
    result.gain_map = FloatImage(external.gain_map.width, external.gain_map.height, 1);
    for (std::size_t index = 0; index < external.gain_map.pixels.size(); ++index) {
      const float log_gain = external.gain_map.pixels[index];
      stops.push_back(log_gain);
      const float fraction = std::abs(max_gain - min_gain) < 1.0e-8F
                                 ? 0.0F
                                 : std::clamp((log_gain - min_gain) / (max_gain - min_gain), 0.0F, 1.0F);
      result.gain_map.pixels[index] = std::pow(fraction, gamma);
    }
  } else {
    result.gain_map = std::move(external.gain_map);
    result.metadata.gain_min = {0, 1};
    result.metadata.gain_max = rational_from_float(max_stops);
    result.metadata.gamma = {1, 1};
    result.metadata.base_offset = {0, 1};
    result.metadata.alternate_offset = {0, 1};
    result.metadata.base_headroom = {0, 1};
    result.metadata.alternate_headroom = rational_from_float(max_stops);
    result.metadata.use_base_color_space = true;
    stops = decoded_stops(result.gain_map, max_stops);
  }
  result.headroom_stops = rational_value(result.metadata.alternate_headroom);

  auto& stats = result.stats;
  stats.headroom_stops = result.headroom_stops;
  stats.headroom_linear = std::exp2(result.headroom_stops);
  stats.rendered_peak = std::exp2(result.headroom_stops);
  stats.headroom_utilization = result.headroom_stops > 0.0F ? 1.0F : 0.0F;
  stats.gain_min_stops = rational_value(result.metadata.gain_min);
  stats.gain_max_stops = rational_value(result.metadata.gain_max);
  stats.gain_gamma = rational_value(result.metadata.gamma);

  const auto count = static_cast<float>(stops.size());
  if (count == 0.0F) return;
  for (const float value : stops) {
    if (value > 0.5F) stats.gain_fraction_gt_0_5 += 1.0F;
    if (value > 1.0F) stats.gain_fraction_gt_1_0 += 1.0F;
    if (value > 2.0F) stats.gain_fraction_gt_2_0 += 1.0F;
    if (value >= stats.gain_max_stops && stats.gain_max_stops > stats.gain_min_stops) {
      stats.gain_clipped_fraction += 1.0F;
    }
  }
  stats.gain_fraction_gt_0_5 /= count;
  stats.gain_fraction_gt_1_0 /= count;
  stats.gain_fraction_gt_2_0 /= count;
  stats.gain_clipped_fraction /= count;
  constexpr std::array<float, 8> kPercentiles{
      0.50F, 0.75F, 0.90F, 0.95F, 0.99F, 0.999F, 0.9999F, 1.0F};
  for (std::size_t index = 0; index < kPercentiles.size(); ++index) {
    auto sample = stops;
    stats.gain_percentiles[index] = percentile(sample, kPercentiles[index]);
  }
}

GainMapResult make_external_gain_map(const FloatImage& source,
                                     ExternalGainMap external,
                                     float strength) {
  if (source.channels != 3) {
    throw std::invalid_argument("external gain input must be RGB");
  }
  if (!std::isfinite(strength) || strength < 0.0F || strength > 1.0F) {
    throw std::invalid_argument("external gain strength must be in [0, 1]");
  }
  // Scale in canonical log2 space before quantising to the ISO code range.
  if (external.canonical_log2) {
    for (float& value : external.gain_map.pixels) value *= strength;
    if (std::abs(strength - 1.0F) > 1.0e-7F) {
      external.metadata.gain_min = rational_from_float(
          rational_value(external.metadata.gain_min) * strength);
      external.metadata.gain_max = rational_from_float(
          rational_value(external.metadata.gain_max) * strength);
      external.metadata.base_headroom = rational_from_float(
          rational_value(external.metadata.base_headroom) * strength);
      external.metadata.alternate_headroom = rational_from_float(
          rational_value(external.metadata.alternate_headroom) * strength);
    }
    external.max_stops = rational_value(external.metadata.gain_max);
  } else {
    external.max_stops *= strength;
  }
  GainMapResult result;
  result.base_linear = FloatImage(source.width, source.height, 3);
  for (std::size_t index = 0; index < source.pixels.size(); ++index) {
    const float value = source.pixels[index];
    result.base_linear.pixels[index] =
        std::isfinite(value) ? std::clamp(value, 0.0F, 1.0F) : 0.0F;
  }
  result.exposure_ev = 0.0F;
  apply_external_gain_map(result, std::move(external));
  return result;
}

}  // namespace hyperdr

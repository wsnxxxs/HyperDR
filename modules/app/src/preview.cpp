#include "hyperdr/app/preview.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/rational.hpp"
#include <cmath>
#include <cstring>
#include <algorithm>

namespace hyperdr {
std::vector<std::uint8_t> compact_preview_packet(const GainMapResult& result,
    const DecodeInfo& decode, const InputDescription& input) {
  const auto& base = result.base_linear;
  const auto& gain = result.gain_map;
  const auto channel = gain_map_channel(result.metadata, 0);
  const auto base_bytes = base.pixels.size() * sizeof(float);
  const auto gain_bytes = gain.pixels.size() * sizeof(float);
  const auto base_id = std::to_string(base.width) + "x" + std::to_string(base.height) + "-" +
      fnv1a_hex(std::string_view(reinterpret_cast<const char*>(base.pixels.data()), base_bytes));
  const float base_headroom = rational_value(result.metadata.base_headroom);
  const float denominator = rational_value(result.metadata.alternate_headroom) - base_headroom;
  const float weight = std::abs(denominator) < 1e-8F ? 0.0F
      : std::clamp((result.headroom_stops - base_headroom) / denominator, 0.0F, 1.0F);
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.native-preview/v2")
      .member("width", base.width).member("height", base.height)
      .member("channels", 3).member("layout", "HWC")
      .member("sampleType", "float32-le").member("colorSpace", "linear-display-p3")
      .member("relativeSdrWhite", 1.0F).member("baseId", base_id)
      .member("gainWidth", gain.width).member("gainHeight", gain.height)
      .member("gainMin", rational_value(channel.gain_min))
      .member("gainMax", rational_value(channel.gain_max))
      .member("gainGamma", rational_value(channel.gamma))
      .member("gainWeight", weight)
      .member("baseOffset", rational_value(channel.base_offset))
      .member("alternateOffset", rational_value(channel.alternate_offset))
      .member("headroomStops", result.headroom_stops)
      .member("inputDomain", input_domain_name(input.domain))
      .member("inputHeadroomStops", std::log2(input.headroom))
      .member("status", decode.degraded ? "degraded" : "ok")
      .begin_array("degradationReasons");
  for (const auto& reason : decode.degradation_reasons) writer.element(reason);
  auto metadata = writer.end_array().end_object().take();
  while (metadata.size() % 4) metadata += ' ';
  std::vector<std::uint8_t> bytes(12 + metadata.size() + base_bytes + gain_bytes);
  std::memcpy(bytes.data(), "HYPREV2\n", 8);
  const auto size = static_cast<std::uint32_t>(metadata.size());
  for (unsigned i = 0; i < 4; ++i) bytes[8 + i] = static_cast<std::uint8_t>(size >> (8 * i));
  std::memcpy(bytes.data() + 12, metadata.data(), metadata.size());
  std::memcpy(bytes.data() + 12 + metadata.size(), base.pixels.data(), base_bytes);
  std::memcpy(bytes.data() + 12 + metadata.size() + base_bytes, gain.pixels.data(), gain_bytes);
  return bytes;
}
}

#pragma once
// Bounded, codec-independent HEIF reader. The input bytes must outlive the
// returned file and its properties. Keep the file alive while using an image
// plan: tile extent spans borrow its item table. No pixel data is decoded.
#include <map>
#include <stdexcept>
#include <string>
#include <utility>

#include "hyperdr/container/heif_limits.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/container/inspect.hpp"

namespace hyperdr {

class HeifReadError : public std::runtime_error {
 public:
  explicit HeifReadError(std::string message, std::string feature = {});
  // Same spellings as the engine/C ABI; codec maps this exception at its edge.
  [[nodiscard]] const char* code() const noexcept {
    return feature_.empty() ? "decode_failed" : "unsupported_format";
  }
  [[nodiscard]] const std::string& feature() const noexcept { return feature_; }
  [[nodiscard]] std::string detail_json() const;

 private:
  std::string feature_;
};
struct HvcConfig {
  std::vector<std::uint8_t> record;
  std::vector<std::vector<std::uint8_t>> parameter_sets;
  unsigned length_size{}, bit_depth{}, chroma_format{}, profile{};
  std::uint32_t width{}, height{};  // SPS after conformance window
  std::optional<HeifNclx> vui_color;
  std::optional<unsigned> chroma_location_top, chroma_location_bottom;
};
[[nodiscard]] HvcConfig parse_hevc_configuration(std::span<const std::uint8_t> bytes);
// Validates complete sample framing, single-layer headers, IRAP and in-band
// parameters before handing untrusted bytes to VideoToolbox. No slice decode.
void validate_hevc_sample(std::span<const std::uint8_t> bytes, const HvcConfig& config);
struct HeifExtent {
  std::uint64_t offset{}, length{};
};
struct HeifAssociation {
  std::uint16_t index{};
  bool essential{};
};
struct HeifProperty {
  std::string type;
  std::span<const std::uint8_t> payload;
};
struct HeifItem {
  std::uint32_t id{};
  std::string type, content_type;
  bool hidden{};
  std::vector<HeifExtent> extents;
  std::vector<HeifAssociation> properties;
};
struct HeifReference {
  std::string type;
  std::uint32_t from{};
  std::vector<std::uint32_t> to;
};
struct HeifGroup {
  std::string type;
  std::uint32_t id{};
  std::vector<std::uint32_t> members;
};
struct HeifTransform {
  std::string type;
  unsigned value{};
  // clap: left, top, width, height in integer pixels at this point in order.
  std::uint32_t left{}, top{}, width{}, height{};
};
struct HeifTile {
  std::uint32_t id{};
  std::span<const HeifExtent> extents;
};
struct HeifImagePlan {
  std::uint32_t item_id{}, width{}, height{}, tile_width{}, tile_height{}, columns{1}, rows{1};
  HvcConfig config;
  std::vector<HeifTile> tiles;
  std::vector<HeifTransform> transforms;
  std::optional<HeifNclx> color;
  std::span<const std::uint8_t> icc, mastering_display;
  std::optional<HeifContentLight> light;
  std::vector<unsigned> channel_bits;
};
struct HeifGainMapPlan {
  HeifImagePlan base, gain;
  std::optional<GainMapMetadata> metadata;  // absent for Apple's legacy URN
  std::uint32_t metadata_id{};
};
struct HeifAlphaPlan {
  HeifImagePlan image;
  bool premultiplied{};
};
class HeifFile {
 public:
  std::span<const std::uint8_t> bytes;
  std::uint32_t primary_item_id{};
  std::vector<std::string> brands;
  std::map<std::uint32_t, HeifItem> items;
  std::vector<HeifProperty> properties;
  std::vector<HeifReference> references;
  std::vector<HeifGroup> groups;
  std::vector<BoxInfo> boxes;
  bool has_data_information{};
  [[nodiscard]] const HeifItem& item(std::uint32_t id) const;
  [[nodiscard]] std::vector<std::uint8_t> item_bytes(
      std::uint32_t id, std::size_t limit = heif_limits::sample_bytes) const;
  [[nodiscard]] std::vector<std::uint32_t> targets(std::uint32_t id, const std::string& type) const;
  [[nodiscard]] HeifImagePlan resolve_image(std::uint32_t id = 0) const;
  [[nodiscard]] std::optional<TmapReferences> tmap_references() const;
  [[nodiscard]] std::optional<HeifGainMapPlan> resolve_gain_map() const;
  [[nodiscard]] std::optional<HeifAlphaPlan> resolve_alpha(std::uint32_t base = 0) const;
  [[nodiscard]] std::string auxiliary_type(std::uint32_t id) const;
  [[nodiscard]] std::vector<std::uint8_t> exif(std::uint32_t image = 0) const;
  [[nodiscard]] std::string xmp(std::uint32_t image = 0) const;
  [[nodiscard]] std::string normalized_json() const;
};
[[nodiscard]] HeifFile read_heif(std::span<const std::uint8_t> bytes);
}  // namespace hyperdr

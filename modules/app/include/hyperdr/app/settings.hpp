#pragma once

// Everything one `convert` run was asked to do, and what it reported back.

#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/gainmap/types.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace hyperdr {

enum class DecodeIntent {
  Export,
  Preview,
};

struct ConvertOptions {
  std::filesystem::path input;
  std::filesystem::path output_directory;
  bool recursive{false};
  bool overwrite{false};
  bool skip_existing{false};
  bool verify_output{true};
  // Zero keeps the original resolution. Non-zero bounds the decoded image
  // before the look and gain-map pipeline.
  std::uint32_t preview_max_edge{0};
  // Explicit workflow intent. Code must not infer this later from a size,
  // cache directory, quality setting, or other side-effect signal.
  DecodeIntent decode_intent{DecodeIntent::Export};
  int quality{90};
  // 8-bit matches what the iPhone camera itself writes for gain-map HEICs and
  // has the broadest decoder support; 10 selects HEVC Main10 (which requires
  // the multibit x265 runtime).
  int depth{8};
  HdrEncoding encoding{HdrEncoding::Adaptive};
  RawDecodeOptions raw;
  GainMapOptions gain;
  std::filesystem::path report_path;
  // Optional raw gain-grid output from an external model. The JSON sidecar is
  // required because the raw file carries neither dimensions nor scale.
  std::filesystem::path external_gain_path;
  std::filesystem::path external_gain_report;
  // Explicitly re-enable the frozen v1 normalized sidecar contract.
  bool allow_legacy_external_gain{false};
  // Optional directory for cached decoded buffers. Interactive preview reruns
  // change only post-decode look controls, so caching the decode turns each
  // slider move from a full RAW read into a file copy.
  std::filesystem::path decode_cache_directory;
  std::uint64_t decode_cache_budget_bytes{2ULL * 1024ULL * 1024ULL * 1024ULL};
};

// Rejects combinations no encoder can honour, before any file is opened.
void validate_convert_options(const ConvertOptions& options);

// Rejects a rendered peak that the selected transfer function cannot encode.
// This second boundary matters for external gain maps: their authoritative
// metadata is not known when ConvertOptions is first validated.
void validate_encoding_headroom(HdrEncoding encoding, float headroom_stops);

struct FileResult {
  std::filesystem::path input;
  std::filesystem::path output;
  bool success{false};
  bool skipped{false};
  bool self_verified{false};
  std::string message;
  std::uint32_t sensor_width{};
  std::uint32_t sensor_height{};
  std::uint32_t target_width{};
  std::uint32_t target_height{};
  std::uint32_t decoded_width{};
  std::uint32_t decoded_height{};
  // Unambiguous crop vocabulary for model bindings. target_*/decoded_* remain
  // as compatibility aliases in schema 7.
  std::uint32_t requested_crop_width{};
  std::uint32_t requested_crop_height{};
  std::uint32_t delivered_crop_width{};
  std::uint32_t delivered_crop_height{};
  // See DecodeInfo: target_dimensions_applied is the only one of these a
  // consumer may branch on, and the reasons are presentation only.
  bool target_dimensions_applied{true};
  bool default_crop_present{false};
  bool decode_degraded{false};
  std::vector<std::string> decode_degradation_reasons;
  std::uint32_t width{};
  std::uint32_t height{};
  double exposure_ev{};
  double headroom_stops{};
  double gain_min{};
  double gain_max{};
  double decode_ms{};
  double process_ms{};
  double encode_ms{};
  RenderStats stats;
};

}  // namespace hyperdr

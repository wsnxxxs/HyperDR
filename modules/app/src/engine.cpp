#include "hyperdr/app/engine.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/version.hpp"
#include "hyperdr/model/ncnn_runtime.hpp"

#include <algorithm>

namespace hyperdr {

void PreviewRegion::resolve(std::uint32_t image_width, std::uint32_t image_height) {
  if (!width || !height || *width == 0 || *height == 0 ||
      *width > 2048 || *height > 2048 || image_width == 0 || image_height == 0 ||
      (!center && (!left || !top))) {
    throw std::invalid_argument("detail region must have a position and be at most 2048 pixels per side");
  }
  *width = std::min(*width, image_width);
  *height = std::min(*height, image_height);
  if (center) {
    left = (image_width - *width) / 2;
    top = (image_height - *height) / 2;
  } else {
    left = std::min(*left, image_width - *width);
    top = std::min(*top, image_height - *height);
  }
}

Engine::Engine(EngineConfig config) : config_(std::move(config)) {
  if (config_.heic_tile_workers > 4) throw std::invalid_argument("heic_tile_workers must be in [0,4]");
#if HYPERDR_WITH_NCNN
  static std::once_flag initialized;
  std::call_once(initialized, install_embedded_ncnn_runtime);
#endif
}
std::unique_ptr<PreviewSession> Engine::preview_open(const std::filesystem::path& source,
    std::string sha256) const {
  return std::make_unique<PreviewSession>(source, std::move(sha256), config_);
}
std::string Engine::convert(ConvertOptions options, ProgressSink* sink,
    const CancelToken* cancel, int* exit_code) const {
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  if (options.decode_cache_directory.empty()) options.decode_cache_directory = config_.cache_directory;
  std::string report;
  const int status = run_conversion(options, sink, &report);
  if (exit_code) *exit_code = status;
  return report;
}
std::string Engine::capabilities() const {
  json::Writer writer;
  writer.begin_object().member("schema", "hyperdr.capabilities/v1")
      .member("version", kVersion).member("buildFingerprint", codec_runtime_fingerprint())
      .member("codecs", kCodecsAvailable).member("memoryBudgetBytes", config_.memory_budget_bytes)
      .member("heicTileWorkers", config_.heic_tile_workers)
      .raw_member("models", native_model_list_json()).begin_array("encodings");
  for (auto encoding : {OutputEncoding::Adaptive, OutputEncoding::IsoGainMapJpeg, OutputEncoding::Pq,
      OutputEncoding::Hlg, OutputEncoding::AvifPq, OutputEncoding::AvifHlg,
      OutputEncoding::SdrJpeg, OutputEncoding::SdrTiff}) {
    const bool hevc = encoding == OutputEncoding::Adaptive || encoding == OutputEncoding::Pq || encoding == OutputEncoding::Hlg;
    writer.begin_object().member("id", hdr_encoding_name(encoding))
        .member("available", kCodecsAvailable && !hevc)
        .member("reason", !kCodecsAvailable ? "codecs_unavailable" : hevc ? "hevc_encoder_unavailable" : "")
        .end_object();
  }
  return writer.end_array().end_object().take() + '\n';
}
std::string Engine::probe(const std::filesystem::path& source) const {
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  // This uses the shared oriented decoder, including RAW default-crop rules.
  // Header-only probing can replace the decode without changing this document.
  const auto decoded = decode_image(source, RawDecodeOptions{});
  json::Writer writer;
  writer.begin_object().member("schema", "hyperdr.probe/v1")
      .member("path", path_utf8(source)).member("width", decoded.linear_p3.width)
      .member("height", decoded.linear_p3.height).member("orientation", decoded.metadata.orientation)
      .member("inputDomain", input_domain_name(decoded.describe_input().domain))
      .member("headroom", decoded.describe_input().headroom)
      .member("degraded", decoded.decode.degraded).begin_object("sourceColor")
      .member("name", decoded.source_color.name).member("primaries", decoded.source_color.primaries)
      .member("transfer", decoded.source_color.transfer).member("source", decoded.source_color.source)
      .end_object().end_object();
  return writer.take() + '\n';
}

std::string frame_layout(const json::Value& frame, std::uint32_t photo_width,
                         std::uint32_t photo_height) {
  return frame_layout_json(layout_frame(parse_frame_spec(frame), photo_width, photo_height)) + '\n';
}

std::string Engine::raw_metadata(const std::filesystem::path& source) const {
  const auto metadata = probe_raw_lens_metadata(source);
  json::Writer writer;
  writer.begin_object().member("make", metadata.make).member("model", metadata.model)
      .member("lens", metadata.lens).member("focalLength", metadata.focal_length)
      .member("aperture", metadata.aperture).end_object();
  return writer.take() + '\n';
}

}  // namespace hyperdr

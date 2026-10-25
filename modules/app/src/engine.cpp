#include "hyperdr/app/engine.hpp"
#include "encoder_capabilities.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/version.hpp"

#include <algorithm>
#include "hyperdr/image/frame.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/codec/raw_compat.hpp"

namespace hyperdr {
namespace {
std::uint64_t effective_memory_budget(std::uint64_t configured) {
  const auto physical = physical_memory_bytes();
  if (!physical) return configured;
  constexpr std::uint64_t reserve = 512ULL * 1024 * 1024;
  const auto host = physical > reserve ? physical - reserve : 0;
  return configured ? std::min(configured, host) : host;
}
}



Engine::Engine(EngineConfig config) : config_(std::move(config)) {
  app::detail::validate_hevc_override(config_.hevc_override);
  if (config_.heic_tile_workers > 4) throw std::invalid_argument("heic_tile_workers must be in [0,4]");

}


std::string Engine::package_rows(const PackageRequest& request,std::uint32_t rows,const PackageRows& read,const CancelToken* cancel,
    const PackageProgress* progress) const {
  CancelScope cancellation(cancel);
  PackageProgressScope reporting(progress);
  ExecutionScope execution({config_.heic_tile_workers,config_.memory_budget_bytes});
  return package_image_rows(request,rows,read);
}
std::string Engine::package(const PackageRequest& request, const CancelToken* cancel) const {
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  return package_image(request);
}
std::string Engine::capabilities() const {
  const auto caps = app::detail::effective_encoder_capabilities(config_.cache_directory, config_.hevc_override);
  json::Writer writer;
  writer.begin_object().member("schema", "hyperdr.capabilities/v1")
      .member("version", kVersion).member("buildFingerprint", codec_runtime_fingerprint())
      .member("codecs", kCodecsAvailable).member("memoryBudgetBytes", config_.memory_budget_bytes)
      .member("effectiveMemoryBudgetBytes",
              effective_memory_budget(config_.memory_budget_bytes))
      .member("raw_converter", raw_converter_id())
      .member("heicTileWorkers", config_.heic_tile_workers)
      .begin_object("encoder").member("backend", "videotoolbox")
      .member("main8", caps.main8).member("main10", caps.main10)
      .member("state", caps.reason == "hevc_probe_failed" ? "failed" : caps.main8 ? "ready" : "unavailable")
      .member("reason", caps.reason).end_object().begin_array("encodings");
  for (auto encoding : {OutputEncoding::Adaptive, OutputEncoding::IsoGainMapJpeg, OutputEncoding::Pq,
      OutputEncoding::Hlg, OutputEncoding::AvifPq, OutputEncoding::AvifHlg,
      OutputEncoding::SdrJpeg, OutputEncoding::SdrTiff}) {
    const bool hevc = encoding == OutputEncoding::Adaptive || encoding == OutputEncoding::Pq || encoding == OutputEncoding::Hlg;
    const auto reason = !kCodecsAvailable ? std::string("codecs_unavailable")
        : hevc ? app::detail::encoder_failure(caps, encoding != OutputEncoding::Adaptive) : std::string{};
    writer.begin_object().member("id", hdr_encoding_name(encoding))
        .member("available", reason.empty())
        .member("reason", reason)
        .end_object();
  }
  return writer.end_array().end_object().take() + '\n';
}
std::string Engine::raw_convert_dng(const std::filesystem::path& raw,
                                     const std::filesystem::path& dng, const CancelToken* cancel) const {
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  return hyperdr::raw_convert_dng(raw, dng);
}
std::string Engine::raw_extract_preview(const std::filesystem::path& raw,
                                         const std::filesystem::path& jpeg, const CancelToken* cancel) const {
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  return hyperdr::raw_extract_preview(raw, jpeg);
}

std::string Engine::probe(const std::filesystem::path& source) const {
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  if (is_raw_extension(lower_extension(source))) {
    const auto header=probe_apple_raw(source);
    json::Writer writer;
    writer.begin_object().member("schema", "hyperdr.probe/v1")
        .member("path",path_utf8(source)).member("width",header.width).member("height",header.height)
        .member("orientation",1).member("inputDomain","scene-referred").member("headroom",1)
        .member("degraded",false).begin_object("sourceColor")
        .member("name","Apple RAW").member("primaries","Display P3")
        .member("transfer","Scene-linear").member("source","apple-ciraw").end_object()
        .begin_object("raw").member("supported",true)
        .member("lensCorrectionSupported",header.processing.lens_correction_supported)
        .member("decoderVersion",header.processing.decoder_version).member("osBuild",raw_os_build()).end_object().end_object();
    return writer.take()+'\n';
  }
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



}  // namespace hyperdr

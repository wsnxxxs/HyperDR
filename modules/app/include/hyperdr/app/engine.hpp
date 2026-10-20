#pragma once

#include "hyperdr/app/package.hpp"
#include "hyperdr/app/settings.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/foundation/json.hpp"

#include <memory>
#include <mutex>

namespace hyperdr {

struct PreviewRegion {
  std::optional<std::uint32_t> left, top, width, height;
  bool center{false};
  [[nodiscard]] bool requested() const { return left || top || width || height || center; }
  void resolve(std::uint32_t image_width, std::uint32_t image_height);
};
struct EngineConfig {
  std::filesystem::path cache_directory;
  std::uint64_t memory_budget_bytes{};
  unsigned heic_tile_workers{};
  // Test-only capability override; never read from the environment by the engine.
  std::string hevc_override;
};
class Busy : public std::runtime_error {
 public:
  Busy() : std::runtime_error("preview session is busy") {}
};
struct PreviewPixels {
  std::string metadata;
  FloatImage base, gain;
  bool compact{};
};
class PreviewSession {
 public:
  PreviewSession(std::filesystem::path source, std::string sha256, EngineConfig config);
  ~PreviewSession();
  PreviewSession(const PreviewSession&) = delete;
  PreviewSession& operator=(const PreviewSession&) = delete;
  // A session owns its decoded sources. Concurrent work on one session returns
  // busy; separate sessions and engines may execute on separate threads.
  [[nodiscard]] std::vector<std::uint8_t> render(ConvertOptions options,
      PreviewRegion region = {}, const CancelToken* cancel = nullptr, bool compact = true);
  [[nodiscard]] PreviewPixels render_pixels(ConvertOptions options,
      PreviewRegion region = {}, const CancelToken* cancel = nullptr, bool compact = true);
  [[nodiscard]] std::vector<std::uint8_t> model_gain(ConvertOptions options,
      const CancelToken* cancel = nullptr);
 private:
  struct State;
  std::unique_ptr<State> state_;
  std::filesystem::path source_;
  std::string sha256_;
  EngineConfig config_;
  std::mutex mutex_;
};
class Engine {
 public:
  explicit Engine(EngineConfig config = {});
  // Opening is lazy: the first render/model call decodes the bound source.
  [[nodiscard]] std::unique_ptr<PreviewSession> preview_open(
      const std::filesystem::path& source, std::string sha256 = {}) const;
  [[nodiscard]] std::string capabilities() const;
  [[nodiscard]] std::string probe(const std::filesystem::path& source) const;
  [[nodiscard]] std::string raw_metadata(const std::filesystem::path& source) const;
  // A completed batch returns its report; inspect per-file success. exit_code
  // optionally provides the CLI aggregate status. Cancellation throws Cancelled.
  [[nodiscard]] std::string convert(ConvertOptions options, ProgressSink* sink = nullptr,
      const CancelToken* cancel = nullptr, int* exit_code = nullptr) const;
  // Writes an already-rendered SDR base and gain plane (P7). Shares this
  // engine's execution configuration with `convert`, so tile workers and the
  // memory budget apply to the same encoders.
  [[nodiscard]] std::string package_rows(const PackageRequest&, std::uint32_t rows,
      const PackageRows&, const CancelToken* cancel = nullptr) const;
  [[nodiscard]] std::string package(const PackageRequest& request,
      const CancelToken* cancel = nullptr) const;
 private:
  EngineConfig config_;
};

// Normalize the panel's camelCase edit controls. The document contains canonical
// renderer settings plus a `command` object for source/output/model plumbing.
// command_line emits a JSON argv array, preserving paths without shell escaping.
[[nodiscard]] std::string normalize_options(const json::Value& edit);
[[nodiscard]] std::vector<std::string> command_line(const json::Value& normalized);
[[nodiscard]] ConvertOptions request_options(const json::Value& request);
// The pixel layout of a presentation frame (hyperdr.frame/v1) around a photo of
// the given oriented size, as frame-layout prints it. Pure: no file is opened.
[[nodiscard]] std::string frame_layout(const json::Value& frame, std::uint32_t photo_width,
                                       std::uint32_t photo_height);
[[nodiscard]] PreviewRegion request_region(const json::Value& request);

}  // namespace hyperdr

#pragma once
#include "hyperdr/app/package.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/json.hpp"
namespace hyperdr {
struct EngineConfig {
  std::filesystem::path cache_directory;
  std::uint64_t memory_budget_bytes{};
  unsigned heic_tile_workers{};
  std::string hevc_override; // Test-only capability override.
};
class Engine {
 public:
  explicit Engine(EngineConfig config = {});
  [[nodiscard]] std::string capabilities() const;
  [[nodiscard]] std::string probe(const std::filesystem::path& source) const;
  [[nodiscard]] std::string package_rows(const PackageRequest&, std::uint32_t rows,
      const PackageRows&, const CancelToken* cancel = nullptr) const;
  [[nodiscard]] std::string package(const PackageRequest&, const CancelToken* cancel = nullptr) const;
 private:
  EngineConfig config_;
};
[[nodiscard]] std::string frame_layout(const json::Value&, std::uint32_t photo_width,
                                     std::uint32_t photo_height);
}

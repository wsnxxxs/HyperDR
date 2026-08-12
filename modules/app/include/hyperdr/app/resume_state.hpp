#pragma once

// The sidecar that records how an output was rendered.
//
// Sidecars live in a single hidden `.hyperdr/` folder mirroring the output tree,
// so a resumable batch never scatters JSON next to the images the user wants. A
// missing or unreadable sidecar means "unknown", which is treated as stale:
// re-rendering costs time, whereas a wrong skip silently ships the previous look.

#include "hyperdr/app/settings.hpp"

#include <cstdint>
#include <filesystem>
#include <string>

namespace hyperdr {

struct InputStamp {
  std::uint64_t size{};
  std::int64_t modified_ns{};
  std::string content_sha256;
  friend bool operator==(const InputStamp&, const InputStamp&) = default;
};

[[nodiscard]] InputStamp input_stamp(const std::filesystem::path& path);

[[nodiscard]] std::filesystem::path resume_state_path(
    const std::filesystem::path& output, const ConvertOptions& options);

[[nodiscard]] bool output_is_current(const std::filesystem::path& output,
                                    const std::filesystem::path& input,
                                    const ConvertOptions& options,
                                    const std::string& fingerprint);

// Best effort. A sidecar is an optimisation, so failing to write one must never
// fail a conversion whose image already landed.
void write_resume_state(const std::filesystem::path& output,
                        const std::filesystem::path& input,
                        InputStamp decoded_input_stamp,
                        const ConvertOptions& options,
                        const std::string& fingerprint);

}  // namespace hyperdr

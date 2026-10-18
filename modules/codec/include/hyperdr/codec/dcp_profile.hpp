#pragma once
#include "hyperdr/codec/resource_snapshot.hpp"
#include "hyperdr/image/dcp_profile.hpp"
#include <filesystem>
#include <string_view>
namespace hyperdr {
[[nodiscard]] DcpProfile read_dcp_profile(const std::filesystem::path& path, const ResourceSnapshot* snapshot = nullptr);
// Static XMP look tables/curves only; adaptive and RGB-table looks are rejected.
void apply_xmp_look(DcpProfile& profile, const std::filesystem::path& path, const ResourceSnapshot* snapshot = nullptr);
[[nodiscard]] bool dcp_matches_camera(const DcpProfile& profile,
    std::string_view make, std::string_view model);
}  // namespace hyperdr

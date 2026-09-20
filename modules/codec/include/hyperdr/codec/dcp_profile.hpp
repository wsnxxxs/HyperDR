#pragma once
#include "hyperdr/image/dcp_profile.hpp"
#include <filesystem>
#include <string_view>
namespace hyperdr {
[[nodiscard]] DcpProfile read_dcp_profile(const std::filesystem::path& path);
[[nodiscard]] bool dcp_matches_camera(const DcpProfile& profile,
    std::string_view make, std::string_view model);
}  // namespace hyperdr

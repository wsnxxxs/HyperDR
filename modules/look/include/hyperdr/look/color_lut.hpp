#pragma once
#include "hyperdr/look/rendition.hpp"
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace hyperdr {
enum class LutSpace { Srgb, DisplayP3, Rec709, Hlg, Pq, SLog3 };
const char* lut_space_name(LutSpace space);
std::optional<LutSpace> lut_space_from_name(std::string_view name);
struct ColorLutOptions {
  std::filesystem::path path;
  LutSpace input{LutSpace::Srgb};
  LutSpace output{LutSpace::Srgb};
  float strength{1};
};
// Adobe/IRIDAS .cube: standalone 1D or 3D, red-fastest RGB table.
// Values outside DOMAIN_MIN/MAX use the nearest boundary, without extrapolation.
struct ColorLut {
  std::string title;
  unsigned size{};
  bool three_dimensional{};
  std::array<float,3> domain_min{0,0,0}, domain_max{1,1,1};
  std::vector<std::array<float,3>> values;
  std::array<float,3> sample(std::array<float,3> rgb) const;
};
ColorLut read_color_lut(const std::filesystem::path& path);
std::array<float,3> encode_lut_space(std::array<float,3> linear_p3, LutSpace space);
std::array<float,3> decode_lut_space(std::array<float,3> rgb, LutSpace space);
void validate_color_lut_options(const ColorLutOptions& options);
void apply_rendition_lut(PhotoRenditions& images, const ColorLutOptions& grade,
    const ColorLut* lut = nullptr);
PhotoRenditions render_graded_photo(const FloatImage& source,
    const RenderOptions& options, const CaptureMetadata& capture,
    const InputDescription& input, RenderTarget target,
    const ColorLutOptions& grade, const ColorLut* lut = nullptr,
    const PhotographicAnalysis* analysis = nullptr,
    GainMapPreparation* preparation = nullptr);
}  // namespace hyperdr

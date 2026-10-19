#pragma once

// A presentation frame around an exported photograph: a mat of one colour, an
// optional soft shadow of the print on it, and an optional caption overlay.
//
// The frame is SDR by construction. `frame_image` writes every frame pixel
// from the spec alone, so the SDR and HDR renditions of one export receive
// bit-identical frames and the gain map packaged from the pair is zero stops
// there. On an HDR screen the frame therefore sits at reference white while
// the photograph keeps all of its headroom, and that is the point: paper white
// beside the print is what makes its highlights read as light.

#include "hyperdr/foundation/json.hpp"
#include "hyperdr/image/image.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>
#include <span>

namespace hyperdr {

// Which edge of the photograph the spec's fractions measure: the short edge
// keeps a portrait and a landscape print on the same mat width.
enum class FrameReference { kShortEdge, kLongEdge };

// Exact decimal rational from the shortest round-tripping JSON number.
// Keeping its power of ten avoids a floating-point decision at a boundary.
struct FrameRatio {
  std::uint64_t significand{};
  int exponent{};
  std::string text;
};

struct FrameAspect {
  std::uint32_t width{}, height{};  // 0:0 explicitly removes the fixed aspect.
  float top_share{0.5F};
};

struct FrameVariant {
  std::string name;
  bool minimum{};  // width/height > threshold; otherwise width/height < threshold.
  FrameRatio threshold;
  std::optional<std::array<float, 4>> margins;  // top, right, bottom, left
  std::optional<float> caption;
  std::optional<FrameReference> reference;
  std::optional<FrameAspect> aspect;
};

struct FrameSpec {
  // Display P3 with the sRGB transfer, as a #RRGGBB colour is written. Always
  // within [0, 1], which is what keeps the frame at or below reference white.
  std::array<float, 3> background{1.0F, 1.0F, 1.0F};
  // Mat widths and the caption band, as fractions of the reference edge. The
  // caption band is extra height under the bottom margin for the overlay.
  float top{}, right{}, bottom{}, left{};
  float caption{};
  FrameReference reference{FrameReference::kShortEdge};
  // Optional fixed canvas proportion, width:height (0:0 keeps the natural
  // canvas). Added height goes above the photo by `aspect_top_share` and to the
  // caption band otherwise; added width is split between the sides.
  std::uint32_t aspect_width{}, aspect_height{};
  float aspect_top_share{0.5F};
  // The print's shadow: darkening at its core, Gaussian sigma and downward
  // offset (fractions of the reference edge). Zero opacity draws none.
  float shadow_opacity{}, shadow_blur{}, shadow_offset{};
  // Optional straight-alpha RGBA PNG exactly the size of the caption band,
  // in Display P3. Transparent pixels show the mat (and the shadow) beneath.
  std::filesystem::path overlay;
  std::vector<FrameVariant> variants;
};

struct FrameRect {
  std::uint32_t x{}, y{}, width{}, height{};
  friend bool operator==(const FrameRect&, const FrameRect&) = default;
};

// Pixel geometry of one framed export. The caption band spans the canvas
// width from the photo's bottom edge to the canvas bottom.
struct FrameLayout {
  std::uint32_t width{}, height{};
  FrameRect photo, caption;
  std::uint32_t reference_edge{};
  std::string variant;  // Empty means the unmodified top-level geometry.
  friend bool operator==(const FrameLayout&, const FrameLayout&) = default;
};

// The decoded caption overlay: interleaved RGBA in [0, 1], colour encoded as
// Display P3 with the sRGB transfer, alpha straight (unassociated).
struct FrameOverlay {
  std::uint32_t width{}, height{};
  std::vector<float> rgba;
};

// Reads a hyperdr.frame/v1 document. Unknown members are errors. A relative
// overlay path resolves against `base_directory` when one is given.
[[nodiscard]] FrameSpec parse_frame_spec(const json::Value& document,
    const std::filesystem::path& base_directory = {});
// The canonical document for a parsed spec: equal specs give equal text, so it
// is what the resume fingerprint and the report record.
[[nodiscard]] std::string frame_spec_json(const FrameSpec& spec);

// Deterministic integer layout. The photo's origin (left and top mats) and the
// canvas width and height are even, so 4:2:0 chroma never straddles the
// print's top-left edge; the right mat and the band below the photo absorb
// the remainder.
[[nodiscard]] FrameLayout layout_frame(const FrameSpec& spec, std::uint32_t photo_width,
                                       std::uint32_t photo_height);
[[nodiscard]] std::string frame_layout_json(const FrameLayout& layout);

// The photo (linear Display P3, three channels) on its framed canvas. Frame
// pixels never read the photo, so framing both renditions with one spec gives
// them the same frame bit for bit. The photo's pixels are copied unchanged.
[[nodiscard]] FloatImage frame_image(const FloatImage& photo, const FrameSpec& spec,
    const FrameLayout& layout, const FrameOverlay* overlay = nullptr);

// A per-pixel byte mask of the photo, placed the same way, with `frame_value`
// in every frame pixel. An empty mask stays empty.
[[nodiscard]] BytePlane frame_mask(std::span<const std::uint8_t> mask,
    const FrameLayout& layout, std::uint8_t frame_value);

}  // namespace hyperdr

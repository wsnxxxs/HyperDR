#include "hyperdr/image/frame.hpp"

#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace hyperdr {
namespace {

constexpr std::string_view kFrameSchema = "hyperdr.frame/v1";
// The canvas may hold a landscape print on a story-shaped canvas, which is
// about four times the print's area; anything far beyond is a mistake.
constexpr double kMaxCanvasToPhotoArea = 6.0;

[[noreturn]] void reject(const std::string& message) {
  throw std::invalid_argument("frame: " + message);
}

const json::Value& object_of(const json::Value& value, std::string_view name) {
  if (!value.is_object()) reject(std::string(name) + " must be an object");
  return value;
}

void allow_members(const json::Value& object, std::string_view name,
                   std::initializer_list<std::string_view> keys) {
  for (const auto& [key, member] : object.members()) {
    if (std::find(keys.begin(), keys.end(), key) == keys.end())
      reject("unknown member " + std::string(name) + "." + key);
  }
}

float fraction(const json::Value& value, std::string_view name, double low, double high) {
  if (!value.is_number()) reject(std::string(name) + " must be a number");
  const double number = value.number();
  if (!std::isfinite(number) || number < low || number > high) {
    reject(std::string(name) + " must be in [" + json::number_text(low) + ", " +
           json::number_text(high) + "]");
  }
  return static_cast<float>(number);
}

std::uint32_t whole(const json::Value& value, std::string_view name) {
  if (!value.is_number()) reject(std::string(name) + " must be a number");
  const double number = value.number();
  if (!(number >= 1 && number <= 100) || std::floor(number) != number)
    reject(std::string(name) + " must be a whole number in [1, 100]");
  return static_cast<std::uint32_t>(number);
}

std::array<float, 3> hex_colour(const json::Value& value) {
  if (!value.is_string()) reject("background must be a #RRGGBB string");
  const auto& text = value.string();
  if (text.size() != 7 || text[0] != '#') reject("background must be a #RRGGBB string");
  std::array<float, 3> colour{};
  for (std::size_t channel = 0; channel < 3; ++channel) {
    int byte = 0;
    for (std::size_t i = 0; i < 2; ++i) {
      const char digit = text[1 + channel * 2 + i];
      int nibble = 0;
      if (digit >= '0' && digit <= '9') nibble = digit - '0';
      else if (digit >= 'a' && digit <= 'f') nibble = digit - 'a' + 10;
      else if (digit >= 'A' && digit <= 'F') nibble = digit - 'A' + 10;
      else reject("background must be a #RRGGBB string");
      byte = byte * 16 + nibble;
    }
    colour[channel] = static_cast<float>(byte) / 255.0F;
  }
  return colour;
}

std::string hex_text(const std::array<float, 3>& colour) {
  constexpr char kDigits[] = "0123456789ABCDEF";
  std::string text = "#";
  for (const float value : colour) {
    const auto byte = static_cast<int>(std::lround(std::clamp(value, 0.0F, 1.0F) * 255.0F));
    text += kDigits[byte / 16];
    text += kDigits[byte % 16];
  }
  return text;
}

// An even pixel count for a fraction of the reference edge.
std::uint64_t even_pixels(float value, double reference) {
  return 2ULL * static_cast<std::uint64_t>(std::llround(static_cast<double>(value) * reference / 2.0));
}

std::uint32_t checked_dimension(std::uint64_t value) {
  if (value > std::numeric_limits<std::uint32_t>::max()) reject("canvas is too large");
  return static_cast<std::uint32_t>(value);
}

// Share of a pixel centred at `t` covered by [low, high) after a Gaussian blur
// with standard deviation `sigma`. Separable, so a blurred rectangle's
// coverage is the product of one call per axis.
float blurred_coverage(double t, double low, double high, double sigma) {
  if (sigma <= 0.0) return t >= low && t < high ? 1.0F : 0.0F;
  const double scale = 1.0 / (sigma * std::sqrt(2.0));
  return static_cast<float>(0.5 * (std::erf((t - low) * scale) - std::erf((t - high) * scale)));
}

}  // namespace

FrameSpec parse_frame_spec(const json::Value& document, const std::filesystem::path& base_directory) {
  object_of(document, "frame");
  allow_members(document, "frame",
      {"schema", "background", "margins", "caption", "reference", "aspect", "shadow", "overlay"});
  FrameSpec spec;
  if (const auto* schema = document.find("schema")) {
    if (!schema->is_string() || schema->string() != kFrameSchema)
      reject("schema must be " + std::string(kFrameSchema));
  }
  if (const auto* background = document.find("background")) spec.background = hex_colour(*background);
  if (const auto* margins = document.find("margins")) {
    if (margins->is_number()) {
      spec.top = spec.right = spec.bottom = spec.left = fraction(*margins, "margins", 0, 0.5);
    } else {
      object_of(*margins, "margins");
      allow_members(*margins, "margins", {"top", "right", "bottom", "left"});
      const auto side = [&](const char* key, float& out) {
        if (const auto* value = margins->find(key)) out = fraction(*value, std::string("margins.") + key, 0, 0.5);
      };
      side("top", spec.top);
      side("right", spec.right);
      side("bottom", spec.bottom);
      side("left", spec.left);
    }
  }
  if (const auto* caption = document.find("caption")) spec.caption = fraction(*caption, "caption", 0, 1);
  if (const auto* reference = document.find("reference")) {
    if (!reference->is_string()) reject("reference must be short or long");
    if (reference->string() == "short") spec.reference = FrameReference::kShortEdge;
    else if (reference->string() == "long") spec.reference = FrameReference::kLongEdge;
    else reject("reference must be short or long");
  }
  if (const auto* aspect = document.find("aspect"); aspect && !aspect->is_null()) {
    object_of(*aspect, "aspect");
    allow_members(*aspect, "aspect", {"width", "height", "topShare"});
    const auto* width = aspect->find("width");
    const auto* height = aspect->find("height");
    if (!width || !height) reject("aspect needs width and height");
    spec.aspect_width = whole(*width, "aspect.width");
    spec.aspect_height = whole(*height, "aspect.height");
    const double ratio = static_cast<double>(spec.aspect_width) / spec.aspect_height;
    if (ratio < 0.25 || ratio > 4.0) reject("aspect must be between 1:4 and 4:1");
    if (const auto* share = aspect->find("topShare")) spec.aspect_top_share = fraction(*share, "aspect.topShare", 0, 1);
  }
  if (const auto* shadow = document.find("shadow"); shadow && !shadow->is_null()) {
    object_of(*shadow, "shadow");
    allow_members(*shadow, "shadow", {"opacity", "blur", "offset"});
    if (const auto* value = shadow->find("opacity")) spec.shadow_opacity = fraction(*value, "shadow.opacity", 0, 1);
    if (const auto* value = shadow->find("blur")) spec.shadow_blur = fraction(*value, "shadow.blur", 0, 0.1);
    if (const auto* value = shadow->find("offset")) spec.shadow_offset = fraction(*value, "shadow.offset", -0.1, 0.1);
  }
  if (const auto* overlay = document.find("overlay"); overlay && !overlay->is_null()) {
    if (!overlay->is_string() || overlay->string().empty()) reject("overlay must be a file path");
    auto path = path_from_utf8(overlay->string());
    if (path.is_relative() && !base_directory.empty()) path = base_directory / path;
    spec.overlay = std::move(path);
  }
  return spec;
}

std::string frame_spec_json(const FrameSpec& spec) {
  json::Writer writer;
  writer.begin_object()
      .member("schema", kFrameSchema)
      .member("background", hex_text(spec.background))
      .begin_object("margins")
      .member("top", spec.top).member("right", spec.right)
      .member("bottom", spec.bottom).member("left", spec.left)
      .end_object()
      .member("caption", spec.caption)
      .member("reference", spec.reference == FrameReference::kShortEdge ? "short" : "long");
  if (spec.aspect_width != 0) {
    writer.begin_object("aspect").member("width", spec.aspect_width)
        .member("height", spec.aspect_height).member("topShare", spec.aspect_top_share).end_object();
  }
  writer.begin_object("shadow").member("opacity", spec.shadow_opacity)
      .member("blur", spec.shadow_blur).member("offset", spec.shadow_offset).end_object();
  if (!spec.overlay.empty()) writer.member("overlay", path_utf8(spec.overlay));
  return writer.end_object().take();
}

FrameLayout layout_frame(const FrameSpec& spec, std::uint32_t photo_width, std::uint32_t photo_height) {
  if (photo_width == 0 || photo_height == 0) reject("photo dimensions must be positive");
  const std::uint32_t reference = spec.reference == FrameReference::kShortEdge
      ? std::min(photo_width, photo_height) : std::max(photo_width, photo_height);
  std::uint64_t top = even_pixels(spec.top, reference);
  std::uint64_t right = even_pixels(spec.right, reference);
  const std::uint64_t bottom = even_pixels(spec.bottom, reference);
  std::uint64_t left = even_pixels(spec.left, reference);
  std::uint64_t caption = even_pixels(spec.caption, reference);
  std::uint64_t width = left + photo_width + right;
  std::uint64_t height = top + photo_height + bottom + caption;

  if (spec.aspect_width != 0 && spec.aspect_height != 0) {
    const auto aw = static_cast<std::uint64_t>(spec.aspect_width);
    const auto ah = static_cast<std::uint64_t>(spec.aspect_height);
    if (width * ah > height * aw) {
      // Too wide for the proportion: add height, above the photo and below it.
      const auto target = static_cast<std::uint64_t>(
          std::llround(static_cast<double>(width) * static_cast<double>(ah) / static_cast<double>(aw)));
      const auto added = target > height ? target - height : 0;
      const auto above = std::min<std::uint64_t>(added & ~1ULL, 2ULL * static_cast<std::uint64_t>(
          std::llround(static_cast<double>(added) * spec.aspect_top_share / 2.0)));
      top += above;
      caption += added - above;
      height += added;
    } else if (width * ah < height * aw) {
      // Too tall: add width, half on each side with the left mat kept even.
      const auto target = static_cast<std::uint64_t>(
          std::llround(static_cast<double>(height) * static_cast<double>(aw) / static_cast<double>(ah)));
      const auto added = target > width ? target - width : 0;
      const auto leftward = 2ULL * static_cast<std::uint64_t>(std::llround(static_cast<double>(added) / 4.0));
      const auto applied = std::min(leftward, added & ~1ULL);
      left += applied;
      right += added - applied;
      width += added;
    }
  }

  const double photo_area = static_cast<double>(photo_width) * photo_height;
  if (static_cast<double>(width) * static_cast<double>(height) > kMaxCanvasToPhotoArea * photo_area + 1.0e6)
    reject("canvas would be more than six times the photo's area");

  FrameLayout layout;
  layout.width = checked_dimension(width);
  layout.height = checked_dimension(height);
  layout.photo = {checked_dimension(left), checked_dimension(top), photo_width, photo_height};
  const auto photo_bottom = layout.photo.y + photo_height;
  layout.caption = {0, photo_bottom, layout.width, layout.height - photo_bottom};
  layout.reference_edge = reference;
  return layout;
}

std::string frame_layout_json(const FrameLayout& layout) {
  json::Writer writer;
  const auto rect = [&](std::string_view key, const FrameRect& r) {
    writer.begin_object(key).member("x", r.x).member("y", r.y)
        .member("width", r.width).member("height", r.height).end_object();
  };
  writer.begin_object().member("schema", "hyperdr.frame-layout/v1")
      .member("width", layout.width).member("height", layout.height);
  rect("photo", layout.photo);
  rect("caption", layout.caption);
  writer.member("referenceEdge", layout.reference_edge);
  return writer.end_object().take();
}

FloatImage frame_image(const FloatImage& photo, const FrameSpec& spec,
                       const FrameLayout& layout, const FrameOverlay* overlay) {
  photo.require_consistent("framed photo");
  if (photo.channels != 3 || photo.width != layout.photo.width || photo.height != layout.photo.height)
    reject("layout was computed for another photo size");
  if (layout.photo.x + static_cast<std::uint64_t>(layout.photo.width) > layout.width ||
      layout.photo.y + static_cast<std::uint64_t>(layout.photo.height) > layout.height)
    reject("photo lies outside the canvas");
  const FrameRect band = layout.caption;
  const bool overlaid = overlay != nullptr && !overlay->rgba.empty();
  if (overlaid) {
    if (overlay->width != band.width || overlay->height != band.height) {
      reject("overlay is " + std::to_string(overlay->width) + "x" + std::to_string(overlay->height) +
             " but the caption band is " + std::to_string(band.width) + "x" + std::to_string(band.height));
    }
    if (overlay->rgba.size() != static_cast<std::size_t>(overlay->width) * overlay->height * 4)
      reject("overlay pixel buffer does not match its size");
  }

  const std::array<float, 3> paper{srgb_eotf(spec.background[0]), srgb_eotf(spec.background[1]),
                                   srgb_eotf(spec.background[2])};
  const bool shadowed = spec.shadow_opacity > 0.0F;
  std::vector<float> shadow_x, shadow_y;
  if (shadowed) {
    const double sigma = static_cast<double>(spec.shadow_blur) * layout.reference_edge;
    const double offset = static_cast<double>(spec.shadow_offset) * layout.reference_edge;
    const double x0 = layout.photo.x, x1 = x0 + layout.photo.width;
    const double y0 = layout.photo.y + offset, y1 = y0 + layout.photo.height;
    shadow_x.resize(layout.width);
    shadow_y.resize(layout.height);
    for (std::uint32_t x = 0; x < layout.width; ++x) shadow_x[x] = blurred_coverage(x + 0.5, x0, x1, sigma);
    for (std::uint32_t y = 0; y < layout.height; ++y) shadow_y[y] = blurred_coverage(y + 0.5, y0, y1, sigma);
  }

  FloatImage canvas(layout.width, layout.height, 3);
  parallel_for_rows(layout.height, [&](std::uint32_t y) {
    float* row = canvas.pixels.data() + static_cast<std::size_t>(y) * layout.width * 3;
    const bool in_band = y >= band.y && y - band.y < band.height;
    const float* ink = overlaid && in_band
        ? overlay->rgba.data() + static_cast<std::size_t>(y - band.y) * overlay->width * 4 : nullptr;
    const auto mat = [&](std::uint32_t from, std::uint32_t to) {
      for (std::uint32_t x = from; x < to; ++x) {
        float* pixel = row + static_cast<std::size_t>(x) * 3;
        // Darkening is multiplicative in light; a fully clear pixel keeps the
        // exact paper value rather than a round trip through the transfer.
        const float keep = shadowed ? 1.0F - spec.shadow_opacity * shadow_x[x] * shadow_y[y] : 1.0F;
        for (int c = 0; c < 3; ++c) pixel[c] = paper[c] * keep;
        if (ink == nullptr) continue;
        const float* source = ink + static_cast<std::size_t>(x) * 4;
        const float alpha = std::clamp(source[3], 0.0F, 1.0F);
        if (!(alpha > 0.0F)) continue;
        // Core Graphics composites text in the encoded space; so does this.
        for (int c = 0; c < 3; ++c) {
          const float below = keep == 1.0F ? spec.background[c] : srgb_oetf(pixel[c]);
          const float colour = std::clamp(source[c], 0.0F, 1.0F);
          pixel[c] = srgb_eotf(alpha * colour + (1.0F - alpha) * below);
        }
      }
    };
    const bool photo_row = y >= layout.photo.y && y - layout.photo.y < layout.photo.height;
    if (!photo_row) {
      mat(0, layout.width);
      return;
    }
    mat(0, layout.photo.x);
    const float* source = photo.pixels.data() +
        static_cast<std::size_t>(y - layout.photo.y) * photo.width * 3;
    std::memcpy(row + static_cast<std::size_t>(layout.photo.x) * 3, source,
                static_cast<std::size_t>(photo.width) * 3 * sizeof(float));
    mat(layout.photo.x + layout.photo.width, layout.width);
  });
  return canvas;
}

std::vector<std::uint8_t> frame_mask(const std::vector<std::uint8_t>& mask,
                                     const FrameLayout& layout, std::uint8_t frame_value) {
  if (mask.empty()) return {};
  if (mask.size() != static_cast<std::size_t>(layout.photo.width) * layout.photo.height)
    reject("mask does not match the photo size");
  std::vector<std::uint8_t> framed(static_cast<std::size_t>(layout.width) * layout.height, frame_value);
  for (std::uint32_t y = 0; y < layout.photo.height; ++y) {
    std::memcpy(framed.data() + static_cast<std::size_t>(layout.photo.y + y) * layout.width + layout.photo.x,
                mask.data() + static_cast<std::size_t>(y) * layout.photo.width, layout.photo.width);
  }
  return framed;
}

}  // namespace hyperdr

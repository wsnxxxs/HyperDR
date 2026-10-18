#include "hyperdr/image/frame.hpp"

#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <charconv>
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

std::array<float, 4> read_margins(const json::Value& value) {
  std::array<float, 4> result{};
  if (value.is_number()) result.fill(fraction(value, "margins", 0, 0.5));
  else {
    object_of(value, "margins");
    allow_members(value, "margins", {"top", "right", "bottom", "left"});
    constexpr const char* sides[] = {"top", "right", "bottom", "left"};
    for (std::size_t i = 0; i < 4; ++i)
      if (const auto* side = value.find(sides[i]))
        result[i] = fraction(*side, std::string("margins.") + sides[i], 0, 0.5);
  }
  return result;
}

FrameReference read_reference(const json::Value& value) {
  if (value.is_string()) {
    if (value.string() == "short") return FrameReference::kShortEdge;
    if (value.string() == "long") return FrameReference::kLongEdge;
  }
  reject("reference must be short or long");
}

FrameAspect read_aspect(const json::Value& value) {
  FrameAspect result;
  if (value.is_null()) return result;
  object_of(value, "aspect");
  allow_members(value, "aspect", {"width", "height", "topShare"});
  const auto* width = value.find("width");
  const auto* height = value.find("height");
  if (!width || !height) reject("aspect needs width and height");
  result.width = whole(*width, "aspect.width");
  result.height = whole(*height, "aspect.height");
  const double ratio = static_cast<double>(result.width) / result.height;
  if (ratio < 0.25 || ratio > 4.0) reject("aspect must be between 1:4 and 4:1");
  if (const auto* share = value.find("topShare"))
    result.top_share = fraction(*share, "aspect.topShare", 0, 1);
  return result;
}

// Use the nearest IEEE double's shortest round-trip decimal, not the original JSON token.
FrameRatio read_ratio(const json::Value& value, bool minimum) {
  const char* key = minimum ? "minRatio" : "maxRatio";
  if (!value.is_number()) reject(std::string(key) + " must be a number");
  const double number = value.number();
  if (!std::isfinite(number) || (minimum ? number <= 1 : number <= 0 || number >= 1))
    reject(std::string(key) + (minimum ? " must be greater than 1" : " must be greater than 0 and less than 1"));
  char text[64];
  const auto [end, error] = std::to_chars(text, text + sizeof(text), number, std::chars_format::scientific);
  if (error != std::errc{}) reject("ratio does not fit its text form");
  FrameRatio ratio;
  ratio.text.assign(text, end);
  bool fractional = false;
  const char* cursor = text;
  for (; cursor != end && *cursor != 'e' && *cursor != 'E'; ++cursor) {
    if (*cursor == '.') { fractional = true; continue; }
    ratio.significand = ratio.significand * 10 + static_cast<unsigned>(*cursor - '0');
    if (fractional) --ratio.exponent;
  }
  if (cursor != end) ratio.exponent += std::stoi(std::string(cursor + 1, static_cast<std::size_t>(end - cursor - 1)));
  return ratio;
}

int compare_ratio(std::uint32_t width, std::uint32_t height, const FrameRatio& ratio) {
  // 17 decimal digits times uint32 dimensions fit in 128 bits. A power of
  // ten that overflows this type is already larger than the other operand.
  using Wide = unsigned __int128;
  Wide left = width, right = static_cast<Wide>(height) * ratio.significand;
  Wide& scaled = ratio.exponent < 0 ? left : right;
  const int power = std::abs(ratio.exponent);
  for (int i = 0; i < power; ++i) {
    if (scaled > ~Wide{0} / 10) return ratio.exponent < 0 ? 1 : -1;
    scaled *= 10;
  }
  return left < right ? -1 : left > right ? 1 : 0;
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
      {"schema", "background", "margins", "caption", "reference", "aspect", "shadow", "overlay", "variants"});
  FrameSpec spec;
  if (const auto* schema = document.find("schema")) {
    if (!schema->is_string() || schema->string() != kFrameSchema)
      reject("schema must be " + std::string(kFrameSchema));
  }
  if (const auto* background = document.find("background")) spec.background = hex_colour(*background);
  if (const auto* margins = document.find("margins")) {
    const auto sides = read_margins(*margins);
    spec.top = sides[0]; spec.right = sides[1]; spec.bottom = sides[2]; spec.left = sides[3];
  }
  if (const auto* caption = document.find("caption")) spec.caption = fraction(*caption, "caption", 0, 1);
  if (const auto* reference = document.find("reference")) spec.reference = read_reference(*reference);
  if (const auto* aspect = document.find("aspect")) {
    const auto value = read_aspect(*aspect);
    spec.aspect_width = value.width; spec.aspect_height = value.height; spec.aspect_top_share = value.top_share;
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
  if (const auto* variants = document.find("variants")) {
    object_of(*variants, "variants");
    if (variants->members().size() > 4) reject("variants allows at most four entries");
    bool has_minimum = false, has_maximum = false;
    for (const auto& [name, value] : variants->members()) {
      if (name.empty() || name.size() > 32 || !std::all_of(name.begin(), name.end(), [](char c) {
          return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'; }))
        reject("variant name must contain 1 to 32 characters from [a-z0-9-]");
      object_of(value, "variant " + name);
      allow_members(value, "variant " + name, {"minRatio", "maxRatio", "margins", "caption", "reference", "aspect"});
      const auto* minimum = value.find("minRatio");
      const auto* maximum = value.find("maxRatio");
      if ((minimum != nullptr) == (maximum != nullptr)) reject("variant " + name + " needs exactly one of minRatio or maxRatio");
      FrameVariant variant;
      variant.name = name;
      variant.minimum = minimum != nullptr;
      variant.threshold = read_ratio(minimum ? *minimum : *maximum, variant.minimum);
      // Each permitted interval is an open ray. Two lower (or two upper)
      // rays always overlap; opposite rays are disjoint by their bounds at 1.
      bool& seen = variant.minimum ? has_minimum : has_maximum;
      if (seen) reject("variant ratio intervals overlap at " + name);
      seen = true;
      if (const auto* margins = value.find("margins")) variant.margins = read_margins(*margins);
      if (const auto* caption = value.find("caption")) variant.caption = fraction(*caption, "caption", 0, 1);
      if (const auto* reference = value.find("reference")) variant.reference = read_reference(*reference);
      if (const auto* aspect = value.find("aspect")) variant.aspect = read_aspect(*aspect);
      spec.variants.push_back(std::move(variant));
    }
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
  if (!spec.variants.empty()) {
    std::vector<const FrameVariant*> sorted;
    for (const auto& variant : spec.variants) sorted.push_back(&variant);
    std::sort(sorted.begin(), sorted.end(), [](const auto* a, const auto* b) { return a->name < b->name; });
    writer.begin_object("variants");
    for (const auto* variant : sorted) {
      writer.begin_object(variant->name).raw_member(variant->minimum ? "minRatio" : "maxRatio", variant->threshold.text);
      if (variant->margins) {
        const auto& m = *variant->margins;
        writer.begin_object("margins").member("top", m[0]).member("right", m[1])
            .member("bottom", m[2]).member("left", m[3]).end_object();
      }
      if (variant->caption) writer.member("caption", *variant->caption);
      if (variant->reference) writer.member("reference", *variant->reference == FrameReference::kShortEdge ? "short" : "long");
      if (variant->aspect) {
        const auto& aspect = *variant->aspect;
        if (aspect.width == 0) writer.null_member("aspect");
        else writer.begin_object("aspect").member("width", aspect.width).member("height", aspect.height)
            .member("topShare", aspect.top_share).end_object();
      }
      writer.end_object();
    }
    writer.end_object();
  }
  return writer.end_object().take();
}

FrameLayout layout_frame(const FrameSpec& requested, std::uint32_t photo_width, std::uint32_t photo_height) {
  if (photo_width == 0 || photo_height == 0) reject("photo dimensions must be positive");
  auto spec = requested;
  std::string selected;
  for (const auto& variant : requested.variants) {
    const int comparison = compare_ratio(photo_width, photo_height, variant.threshold);
    if (variant.minimum ? comparison <= 0 : comparison >= 0) continue;
    selected = variant.name;
    if (variant.margins) {
      const auto& m = *variant.margins;
      spec.top = m[0]; spec.right = m[1]; spec.bottom = m[2]; spec.left = m[3];
    }
    if (variant.caption) spec.caption = *variant.caption;
    if (variant.reference) spec.reference = *variant.reference;
    if (variant.aspect) {
      spec.aspect_width = variant.aspect->width; spec.aspect_height = variant.aspect->height;
      spec.aspect_top_share = variant.aspect->top_share;
    }
    break;
  }
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
  layout.variant = std::move(selected);
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
  if (!layout.variant.empty()) writer.member("variant", layout.variant);
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

// A frame must not take part in the HDR. These cases frame a rendered SDR/HDR
// pair, package it through every gain-map writer the exports use, and
// reconstruct it at full headroom: the mat must come back at its SDR value
// (zero stops of gain) and the photograph must keep its own headroom.

#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/frame.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

using namespace hyperdr;

namespace {

void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}

PhotoRenditions render_scene() {
  // A dim gradient with a bright window: plenty of gain in one corner and
  // none in the rest, like a real photograph.
  FloatImage source(96, 64, 3);
  for (std::uint32_t y = 0; y < 64; ++y) {
    for (std::uint32_t x = 0; x < 96; ++x) {
      const bool window = x > 60 && y < 24;
      for (std::uint32_t c = 0; c < 3; ++c)
        source.at(x, y, c) = window ? 6.0F : 0.05F + 0.3F * static_cast<float>(x) / 96.0F;
    }
  }
  RenderOptions options;
  options.auto_headroom = false;
  options.headroom_stops = 2.5F;
  InputDescription input;
  input.domain = InputDomain::kDisplayReferredHdr;
  input.headroom = 6.0F;
  return render_renditions(source, options, {}, input, RenderTarget::Hdr);
}

PhotoRenditions framed(PhotoRenditions photo, const FrameSpec& spec, const FrameLayout& layout) {
  photo.sdr = frame_image(photo.sdr, spec, layout);
  photo.hdr = frame_image(photo.hdr, spec, layout);
  photo.below_knee = frame_mask(photo.below_knee, layout, 1);
  return photo;
}

struct Packaged {
  FloatImage base, hdr;
  float headroom{};
};

Packaged package(PhotoRenditions photo, GainMapWriterProfile profile) {
  const auto result = gain_map_from_renditions(std::move(photo), profile);
  return {result.base_linear,
          reconstruct_gain_map(result.base_linear, result.gain_map, result.metadata,
                               result.headroom_stops, nullptr, result.clamp_srgb),
          result.headroom_stops};
}

float luminance(const FloatImage& image, std::uint32_t x, std::uint32_t y) {
  return p3_luminance(image.at(x, y, 0), image.at(x, y, 1), image.at(x, y, 2));
}

// How the export packages a model's or an external gain map once framed: as
// an authored pair with the map's own offsets (here the common 1/64).
void as_authored(PhotoRenditions& photo) {
  photo.dual_rendition = true;
  photo.authored_gain_channels = 1;
  photo.authored_gain_map.channels = 1;
  photo.authored_gain_map.base_offset.fill(1.0F / 64.0F);
  photo.authored_gain_map.alternate_offset.fill(1.0F / 64.0F);
}

void check(const char* name, bool hdr_is_source, GainMapWriterProfile profile, bool authored = false) {
  const auto spec = parse_frame_spec(json::parse(R"({"background": "#F4F2EC", "margins": 0.08,
      "caption": 0.12, "shadow": {"opacity": 0.12, "blur": 0.02, "offset": 0.006}})"));
  auto photo = render_scene();
  photo.hdr_is_source = hdr_is_source;
  if (authored) as_authored(photo);
  const auto layout = layout_frame(spec, photo.sdr.width, photo.sdr.height);
  const auto plain = package(photo, profile);
  const auto frame = package(framed(photo, spec, layout), profile);
  const auto mat = frame_image(photo.sdr, spec, layout);

  float photo_peak = 1.0F, frame_peak = 1.0F, mat_error = 0.0F, photo_error = 0.0F;
  for (std::uint32_t y = 0; y < layout.height; ++y) {
    for (std::uint32_t x = 0; x < layout.width; ++x) {
      const bool in_photo = x >= layout.photo.x && x < layout.photo.x + layout.photo.width &&
                            y >= layout.photo.y && y < layout.photo.y + layout.photo.height;
      const float hdr = luminance(frame.hdr, x, y);
      if (!in_photo) {
        // The mat reconstructs to its own SDR value: no gain at all.
        const float paper = luminance(mat, x, y);
        mat_error = std::max(mat_error, std::abs(hdr - paper) / paper);
        require(luminance(frame.base, x, y) <= 1.0F + 1e-6F, "the mat stays in the SDR base");
        continue;
      }
      const auto px = x - layout.photo.x, py = y - layout.photo.y;
      const float reference = luminance(plain.hdr, px, py);
      photo_error = std::max(photo_error, std::abs(hdr - reference) / std::max(reference, 1e-3F));
      photo_peak = std::max(photo_peak, reference);
      frame_peak = std::max(frame_peak, hdr);
    }
  }
  std::cout << name << ": mat error " << mat_error << ", photo error " << photo_error
            << ", peak " << photo_peak << " -> " << frame_peak << '\n';
  require(mat_error < 1e-4F, "the mat must reconstruct at its SDR value");
  // Only the gain code range may move; one 8-bit code over 2.5 stops is ~0.7%.
  require(photo_error < 0.015F, "the photograph must keep its HDR rendition");
  require(std::abs(frame_peak - photo_peak) / photo_peak < 0.01F,
          "the photograph must keep its peak");
  require(std::abs(frame.headroom - plain.headroom) < 0.02F, "declared headroom must not change");
  require(photo_peak > 4.0F, "the scene must actually use its headroom");
}

}  // namespace

int main() {
  try {
    check("adaptive", false, GainMapWriterProfile::apple_strict);
    check("iso rgb", false, GainMapWriterProfile::iso_generic);
    check("hdr source", true, GainMapWriterProfile::apple_strict);
    check("model adaptive", false, GainMapWriterProfile::apple_strict, true);
    check("model iso rgb", false, GainMapWriterProfile::iso_generic, true);
  } catch (const std::exception& error) {
    std::cerr << "frame_gain_test failed: " << error.what() << '\n';
    return 1;
  }
  std::cout << "frame_gain_test passed\n";
  return 0;
}

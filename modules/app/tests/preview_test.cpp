#include "hyperdr/app/preview.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/json.hpp"
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

int main() {
  using namespace hyperdr;
  try {
    for (const auto domain : {InputDomain::kSceneReferred, InputDomain::kDisplayReferredSdr}) {
      FloatImage source(127, 83, 3);
      for (unsigned y = 0; y < source.height; ++y) for (unsigned x = 0; x < source.width; ++x) {
        const float v = static_cast<float>(x) / 126 * (domain == InputDomain::kSceneReferred ? 5 : 1);
        source.at(x,y,0) = v; source.at(x,y,1) = v*.8F; source.at(x,y,2) = v*.6F;
      }
      GainMapOptions options;
      options.auto_exposure = false; options.auto_headroom = false; options.headroom_stops = 2.5F;
      GainMapPreparation preparation;
      InputDescription input; input.domain = domain;
      for (float strength : {.4F, .8F, 0.0F, .001F, 1.0F}) {
        options.gain_strength = strength;
        const auto cached = make_gain_map(source, options, {}, input, nullptr, &preparation);
        const auto fresh = make_gain_map(source, options, {}, input);
        if (cached.base_linear.pixels != fresh.base_linear.pixels ||
            cached.gain_map.pixels != fresh.gain_map.pixels ||
            cached.headroom_stops != fresh.headroom_stops)
          throw std::runtime_error("prepared rendering differs from a fresh render");
        const auto packet = compact_preview_packet(cached, {}, input);
        std::uint32_t size = 0;
        for (unsigned i = 0; i < 4; ++i) size |= static_cast<std::uint32_t>(packet[8+i]) << (8*i);
        if (size % 4) throw std::runtime_error("unaligned compact payload");
        const auto metadata = json::parse(std::string_view(reinterpret_cast<const char*>(packet.data()+12), size));
        if (metadata.find("schema")->string() != "hyperdr.native-preview/v2") throw std::runtime_error("bad schema");
        const auto bytes = cached.base_linear.pixels.size()*sizeof(float);
        if (std::memcmp(packet.data()+12+size, cached.base_linear.pixels.data(), bytes))
          throw std::runtime_error("compact packet changed base pixels");
      }
    }
    SceneStatistics reference;
    for (unsigned edge : {640U, 1280U}) {
      FloatImage ramp(edge, edge / 2, 3);
      for (unsigned y = 0; y < ramp.height; ++y) for (unsigned x = 0; x < edge; ++x)
        for (unsigned c = 0; c < 3; ++c) ramp.at(x,y,c) = .02F + 3.0F*(x+.5F)/edge;
      const auto stats = compute_luminance_statistics(ramp);
      if (edge == 640) reference = stats;
      else if (std::abs(stats.log_average-reference.log_average) > 1e-6F ||
               std::abs(stats.p995-reference.p995) > 1e-6F)
        throw std::runtime_error("reference statistics shift with preview resolution");
    }
    std::cout << "Prepared RAW/SDR renders match fresh pixels across strength and zero; compact packet preserves float base\n";
    return 0;
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}

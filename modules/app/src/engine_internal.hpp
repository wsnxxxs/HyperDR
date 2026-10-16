#pragma once

#include "hyperdr/app/engine.hpp"
#include <functional>

namespace hyperdr {
// Model-gain also accepts its CLI-only tensor path. Image requests obtain the
// decoded source from the preview session, sharing its source cache.
[[nodiscard]] std::vector<std::uint8_t> render_model_gain(ConvertOptions options,
    const std::function<const DecodedImage&(const ConvertOptions&)>& decode);
}

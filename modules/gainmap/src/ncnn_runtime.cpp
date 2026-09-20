#include "hyperdr/model/ncnn_runtime.hpp"

#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/gainmap/research_exif_level.hpp"

#include <net.h>

#include <windows.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

// One RCDATA pair per model. The numbers are frozen in cmake/HyperDRModel.rc.in
// and the resource compiler reads the exact bytes HyperDRModel.cmake selected,
// so a build that is missing an asset fails at startup rather than at the first
// request.
constexpr int kResearchCnnParamResource = 103;
constexpr int kResearchCnnBinResource = 104;
constexpr int kResearchExifParamResource = 105;
constexpr int kResearchExifBinResource = 106;

struct ResourceBytes {
  const unsigned char* data{};
  std::size_t size{};
};

ResourceBytes embedded_resource(int resource_id) {
  const HMODULE module = GetModuleHandleW(nullptr);
  if (module == nullptr) {
    throw std::runtime_error("could not locate HyperDR.exe module");
  }
  const HRSRC resource = FindResourceW(
      module, MAKEINTRESOURCEW(resource_id), MAKEINTRESOURCEW(10));
  if (resource == nullptr) {
    throw std::runtime_error("embedded ncnn model resource is missing");
  }
  const HGLOBAL loaded = LoadResource(module, resource);
  const DWORD size = SizeofResource(module, resource);
  const auto* data = static_cast<const unsigned char*>(
      loaded == nullptr ? nullptr : LockResource(loaded));
  if (data == nullptr || size == 0U) {
    throw std::runtime_error("embedded ncnn model resource is empty");
  }
  return {data, static_cast<std::size_t>(size)};
}

// One loaded network. Each model owns its own instance rather than sharing one
// global Net whose blobs would have to be swapped per request: the panel runs
// previews and exports with different models, and a swap between an extractor's
// creation and its use is the kind of race that only shows up as a wrong
// picture.
struct EmbeddedNcnnRuntime {
  // ncnn retains pointers into the binary model and requires a 32-bit aligned
  // buffer. A PE RCDATA address is not a portable alignment guarantee, so
  // retain an ordinary heap copy for the lifetime of the Net.
  std::vector<unsigned char> weights;
  ncnn::Net network;

  EmbeddedNcnnRuntime(int param_resource, int bin_resource) {
    const auto param = embedded_resource(param_resource);
    const auto weight_resource = embedded_resource(bin_resource);

    // load_param_mem expects a NUL-terminated text buffer.  Keep the copy
    // alive only through loading; ncnn owns the parsed layer metadata after
    // this call.  The binary model is consumed directly from the resource.
    std::string param_text(reinterpret_cast<const char*>(param.data),
                           param.size);
    param_text.push_back('\0');
    // Set this before loading the weights so a Vulkan-enabled ncnn package
    // cannot initialize a GPU backend for the embedded CPU asset.
    network.opt.use_vulkan_compute = false;
    if (network.load_param_mem(param_text.c_str()) != 0) {
      throw std::runtime_error("failed to load embedded ncnn param");
    }
    this->weights.assign(weight_resource.data,
                         weight_resource.data + weight_resource.size);
    // The memory overload returns the number of bytes consumed, not an error
    // code like the file/DataReader overloads; zero denotes failure.
    if (network.load_model(this->weights.data()) == 0U) {
      throw std::runtime_error("failed to load embedded ncnn weights");
    }
  }
};

const EmbeddedNcnnRuntime& runtime_for(std::string_view canonical_id) {
  // Static locals initialize once, under the language's own guard, so two
  // threads asking for the same model at the same time cannot each build it.
  if (canonical_id == kResearchCnnModelId) {
    static const EmbeddedNcnnRuntime runtime(kResearchCnnParamResource,
                                             kResearchCnnBinResource);
    return runtime;
  }
  if (canonical_id == kResearchExifModelId) {
    static const EmbeddedNcnnRuntime runtime(kResearchExifParamResource,
                                             kResearchExifBinResource);
    return runtime;
  }
  throw std::invalid_argument("no embedded ncnn asset for model id " +
                              std::string(canonical_id));
}

// Runs one network over the five deterministic feature planes and returns the
// raw stride-16 grid. Every model in this build shares the same input contract
// and the same head geometry, so one function covers both; a second copy
// would be a second place for the blob names to drift.
FloatImage run_network(const EmbeddedNcnnRuntime& runtime,
                       const FloatImage& features) {
  ncnn::Mat input(static_cast<int>(features.width),
                  static_cast<int>(features.height),
                  static_cast<int>(features.channels), sizeof(float));
  for (std::uint32_t y = 0; y < features.height; ++y) {
    for (std::uint32_t x = 0; x < features.width; ++x) {
      const auto pixel =
          (static_cast<std::size_t>(y) * features.width + x) * features.channels;
      for (std::uint32_t channel = 0; channel < features.channels; ++channel) {
        input.channel(static_cast<int>(channel))[
            static_cast<std::size_t>(y) * features.width + x] =
            features.pixels[pixel + channel];
      }
    }
  }

  auto extractor = runtime.network.create_extractor();
  if (extractor.input("in0", input) != 0) {
    throw std::runtime_error("embedded ncnn model rejected its feature input");
  }
  ncnn::Mat prediction;
  if (extractor.extract("out0", prediction) != 0 || prediction.empty()) {
    throw std::runtime_error("embedded ncnn model failed to produce gain stops");
  }
  if (prediction.dims != 3 ||
      prediction.w != static_cast<int>(features.width / 16U) ||
      prediction.h != static_cast<int>(features.height / 16U) ||
      prediction.c != 1) {
    throw std::runtime_error("embedded ncnn model returned an invalid gain grid");
  }

  FloatImage gain(features.width / 16U, features.height / 16U, 1);
  const float* values = prediction.channel(0);
  std::copy(values, values + gain.pixels.size(), gain.pixels.begin());
  return gain;
}

// The capture vector the research estimator consumes, and whether all six
// fields were recorded. The transform is the training pipeline's
// (`src/prepare.py`) and nothing else: ISO and exposure time are the only two
// that are logged, and the exposure bias is used signed and unlogged because it
// already is a stop count.
struct ExifVector {
  std::array<double, kCaptureParameterCount> features{};
  std::array<bool, kCaptureParameterCount> present{};
  std::vector<std::string> missing;
  bool complete{false};
};

ExifVector build_exif_vector(const CaptureParameters& capture) {
  ExifVector vector;
  vector.complete = capture_parameters_complete(capture, &vector.missing);
  const auto put = [&](std::size_t index, const std::optional<double>& value,
                       double transformed) {
    vector.present[index] = value.has_value();
    vector.features[index] = value.has_value() ? transformed : 0.0;
  };
  put(0, capture.iso, capture.iso ? std::log2(std::max(*capture.iso, 1.0)) : 0.0);
  put(1, capture.exposure_seconds,
      capture.exposure_seconds ? std::log2(std::max(*capture.exposure_seconds, 1.0e-6))
                               : 0.0);
  put(2, capture.f_number, capture.f_number.value_or(0.0));
  put(3, capture.exposure_bias_ev, capture.exposure_bias_ev.value_or(0.0));
  put(4, capture.focal_length_mm, capture.focal_length_mm.value_or(0.0));
  put(5, capture.focal_length_35mm, capture.focal_length_35mm.value_or(0.0));
  return vector;
}

NativeModelOutput infer_embedded_ncnn(const NativeModelRequest& request,
                                      const FloatImage& linear_display_p3_sdr) {
  const auto& features = make_native_model_features(linear_display_p3_sdr);

  if (request.model_id == kResearchExifModelId) {
    const auto exif = build_exif_vector(request.capture);
    if (exif.complete) {
      // Model 2: the spatial network predicts the shape of the gain only --
      // its training target had the per-image level removed -- so the level is
      // restored from the capture settings, and the mean must be taken on this
      // image's own grid after the prediction rather than inside the network.
      auto gain = run_network(runtime_for(kResearchExifModelId), features);
      const double level =
          research_exif_level(exif.features, exif.present);
      if (!std::isfinite(level)) {
        throw std::runtime_error(
            "the exported EXIF level estimator produced a non-finite value; "
            "its generated arrays are inconsistent");
      }
      double sum = 0.0;
      for (const float value : gain.pixels) sum += value;
      const double mean = sum / static_cast<double>(gain.pixels.size());
      for (float& value : gain.pixels) {
        value = static_cast<float>((value - mean) + level);
      }
      return make_native_model_output(kResearchExifModelId, kResearchExifModelId,
                                      kInferenceModeExifAssisted, {},
                                      std::move(gain));
    }
    // A capture with a hole in it does not get six imputed defaults dressed up
    // as a complete one: model 1 answers instead, and the report says which
    // field was missing. The shape-only network is deliberately not used
    // alone -- its training target had no constraint on the overall level, so
    // its raw output is not a complete gain.
    std::string reason("missing_capture_fields");
    for (const auto& field : exif.missing) {
      reason += ":";
      reason += field;
    }
    auto gain = run_network(runtime_for(kResearchCnnModelId), features);
    return make_native_model_output(kResearchExifModelId, kResearchCnnModelId,
                                    kInferenceModeFallback, std::move(reason),
                                    std::move(gain));
  }

  auto gain = run_network(runtime_for(request.model_id), features);
  return make_native_model_output(request.model_id, request.model_id,
                                  kInferenceModePixelOnly, {}, std::move(gain));
}

// Loading every asset once, at startup, turns "the build is missing a model" or
// "pnnx emitted a layer ncnn cannot run" into an immediate failure instead of a
// request that fails after the user has already chosen a photograph.
std::once_flag& installation_once() {
  static std::once_flag once;
  return once;
}

}  // namespace

bool install_embedded_ncnn_runtime() {
  std::call_once(installation_once(), [] {
    for (const auto& descriptor : native_model_table()) {
      (void)runtime_for(descriptor.id);
    }
    set_native_model_runtime(infer_embedded_ncnn);
  });
  return true;
}

}  // namespace hyperdr

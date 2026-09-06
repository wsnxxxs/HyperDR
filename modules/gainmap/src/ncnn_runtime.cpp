#include "hyperdr/model/ncnn_runtime.hpp"

#include "hyperdr/gainmap/native_model.hpp"

#include <net.h>

#include <windows.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

constexpr int kNcnnParamResource = 101;
constexpr int kNcnnBinResource = 102;

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

struct EmbeddedNcnnRuntime {
  // ncnn retains pointers into the binary model and requires a 32-bit aligned
  // buffer. A PE RCDATA address is not a portable alignment guarantee, so
  // retain an ordinary heap copy for the lifetime of the Net.
  std::vector<unsigned char> weights;
  ncnn::Net network;

  EmbeddedNcnnRuntime() {
    const auto param = embedded_resource(kNcnnParamResource);
    const auto weight_resource = embedded_resource(kNcnnBinResource);

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

EmbeddedNcnnRuntime& embedded_runtime() {
  static EmbeddedNcnnRuntime runtime;
  return runtime;
}

NativeModelOutput infer_embedded_ncnn(
    const std::filesystem::path& /*model_artifact*/,
    const FloatImage& linear_display_p3_sdr) {
  const auto features = make_native_model_features(linear_display_p3_sdr);
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

  auto& runtime = embedded_runtime();
  auto extractor = runtime.network.create_extractor();
  if (extractor.input("in0", input) != 0) {
    throw std::runtime_error("embedded ncnn model rejected its feature input");
  }
  ncnn::Mat prediction;
  if (extractor.extract("out0", prediction) != 0 || prediction.empty()) {
    throw std::runtime_error("embedded ncnn model failed to produce gain stops");
  }
  if (prediction.dims != 3 || prediction.w != static_cast<int>(features.width / 16U) ||
      prediction.h != static_cast<int>(features.height / 16U) ||
      prediction.c != 1) {
    throw std::runtime_error("embedded ncnn model returned an invalid gain grid");
  }

  NativeModelOutput output{
      FloatImage(features.width / 16U, features.height / 16U, 1)};
  const float* values = prediction.channel(0);
  std::copy(values, values + output.signed_log2_gain.pixels.size(),
            output.signed_log2_gain.pixels.begin());
  return output;
}

}  // namespace

bool install_embedded_ncnn_runtime() {
  // Force resource/model validation at startup rather than waiting until the
  // first user request.  Static local initialization is thread-safe.
  (void)embedded_runtime();
  set_native_model_runtime(infer_embedded_ncnn);
  return true;
}

}  // namespace hyperdr

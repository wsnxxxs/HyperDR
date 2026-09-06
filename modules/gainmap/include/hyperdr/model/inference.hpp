#pragma once

// Stable include path for model-runtime adapters.  The implementation lives
// with the gain-map module because it owns the in-memory postprocessing path;
// keeping this forwarding header lets an ncnn/DirectML adapter avoid depending
// on application/CLI headers.

#include "hyperdr/gainmap/native_model.hpp"

namespace hyperdr::model {

using ::hyperdr::NativeModelInfer;
using ::hyperdr::NativeModelOutput;
using ::hyperdr::NativeModelPostOptions;
using ::hyperdr::kEmbeddedNativeModel;
using ::hyperdr::kNativeModelStride;
using ::hyperdr::infer_native_model;
using ::hyperdr::kDefaultNativeModelLongSide;
using ::hyperdr::kNativeModelStride;
using ::hyperdr::make_native_model_input;
using ::hyperdr::make_native_model_features;
using ::hyperdr::guided_filter_native_model_gain;
using ::hyperdr::apply_native_model_gain_map;
using ::hyperdr::make_native_model_gain_map;
using ::hyperdr::native_model_runtime_available;
using ::hyperdr::set_native_model_runtime;

}  // namespace hyperdr::model

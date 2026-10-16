#include "hyperdr/hyperdr.h"

#include "hyperdr/app/report.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/version.hpp"

#include <cstdlib>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>

namespace {

void set_error(hyperdr_error** out, const char* code, const char* message) noexcept {
  if (out == nullptr) return;
  const auto size = std::strlen(message) + 1;
  auto* error = static_cast<hyperdr_error*>(std::malloc(sizeof(hyperdr_error) + size));
  if (error == nullptr) return;
  auto* text = reinterpret_cast<char*>(error + 1);
  std::memcpy(text, message, size);
  error->code = code;
  error->message = text;
  *out = error;
}

template <class MakeJson>
int json_result(char** out, hyperdr_error** error, MakeJson make_json) noexcept {
  if (error != nullptr) *error = nullptr;
  if (out != nullptr) *out = nullptr;
  try {
    if (out == nullptr) throw std::invalid_argument("output pointer is required");
    const auto json = make_json();
    auto* text = static_cast<char*>(std::malloc(json.size() + 1));
    if (text == nullptr) throw std::bad_alloc();
    std::memcpy(text, json.c_str(), json.size() + 1);
    *out = text;
    return 0;
  } catch (const std::invalid_argument& exception) {
    set_error(error, "invalid_options", exception.what());
  } catch (const std::bad_alloc&) {
    set_error(error, "out_of_memory", "cannot allocate JSON result");
  } catch (const std::exception& exception) {
    set_error(error, "internal_error", exception.what());
  } catch (...) {
    set_error(error, "internal_error", "unknown native exception");
  }
  return 1;
}

}  // namespace

uint32_t hyperdr_abi_version(void) { return HYPERDR_ABI_VERSION; }
const char* hyperdr_version(void) { return hyperdr::kVersion; }

int hyperdr_schema_json(char** out, hyperdr_error** error) {
  return json_result(out, error, [] { return hyperdr::schema_json(); });
}

int hyperdr_curve_json(const char* settings_json, unsigned samples,
                       char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    if (settings_json == nullptr) throw std::invalid_argument("settings JSON is required");
    hyperdr::ConvertOptions options;
    hyperdr::apply_preset_document(hyperdr::json::parse(settings_json), options);
    return hyperdr::look_curve_json(options.gain, samples) + '\n';
  });
}

void hyperdr_string_free(char* string) { std::free(string); }
void hyperdr_error_free(hyperdr_error* error) { std::free(error); }

#include "hyperdr/hyperdr.h"

#include "hyperdr/app/report.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <unistd.h>
#include <memory>
#include <vector>
#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/version.hpp"

#include <cstdlib>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>

struct hyperdr_engine { hyperdr::Engine value; };
struct hyperdr_preview_session { std::unique_ptr<hyperdr::PreviewSession> value; };
struct hyperdr_cancel { hyperdr::CancelToken value; };

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

template <class Function>
int boundary(hyperdr_error** error, Function function) noexcept {
  if (error) *error = nullptr;
  try {
    function();
    return 0;
  } catch (const hyperdr::Cancelled& exception) {
    set_error(error, "cancelled", exception.what());
  } catch (const hyperdr::Busy& exception) {
    set_error(error, "busy", exception.what());
  } catch (const hyperdr::RawMemoryError& exception) {
    set_error(error, "raw_budget", exception.what());
  } catch (const hyperdr::SourceUnreadable& exception) {
    set_error(error, "source_unreadable", exception.what());
  } catch (const hyperdr::UnsupportedFormat& exception) {
    set_error(error, "unsupported_format", exception.what());
  } catch (const hyperdr::DecodeFailed& exception) {
    set_error(error, "decode_failed", exception.what());
  } catch (const std::invalid_argument& exception) {
    set_error(error, "invalid_options", exception.what());
  } catch (const std::bad_alloc&) {
    set_error(error, "out_of_memory", "cannot allocate native result");
  } catch (const std::exception& exception) {
    set_error(error, "internal_error", exception.what());
  } catch (...) {
    set_error(error, "internal_error", "unknown native exception");
  }
  return 1;
}
template <class T> T& required(T* value) {
  if (!value) throw std::invalid_argument("required pointer is null");
  return *value;
}
hyperdr::json::Value document(const char* text) {
  if (!text) throw std::invalid_argument("request JSON is required");
  return hyperdr::json::parse(text);
}
template <class MakeJson>
int json_result(char** out, hyperdr_error** error, MakeJson make_json) noexcept {
  if (out) *out = nullptr;
  return boundary(error, [&] {
    required(out);
    const auto json = make_json();
    auto* text = static_cast<char*>(std::malloc(json.size() + 1));
    if (!text) throw std::bad_alloc();
    std::memcpy(text, json.c_str(), json.size() + 1);
    *out = text;
  });
}
const hyperdr::CancelToken* token(hyperdr_cancel* cancel) { return cancel ? &cancel->value : nullptr; }
bool compact(const hyperdr::json::Value& request) {
  const auto* command = request.find("command");
  const auto* compact = command ? command->find("compact") : nullptr;
  return compact ? compact->boolean() : true;
}
std::vector<std::uint8_t> render(hyperdr_preview_session* session,
    const hyperdr::json::Value& request, hyperdr_cancel* cancel) {
  return required(session).value->render(hyperdr::request_options(request),
      hyperdr::request_region(request), token(cancel), compact(request));
}
template <class MakeBuffer>
int buffer_result(hyperdr_buffer* out, hyperdr_error** error, MakeBuffer make_buffer) {
  if (out) *out = {};
  return boundary(error, [&] {
    required(out);
    auto bytes = std::make_unique<std::vector<std::uint8_t>>(make_buffer());
    *out = {bytes->data(), bytes->size(), bytes.get()};
    bytes.release();
  });
}
struct FrameOwner {
  std::string metadata;
  void* base{};
  void* gain{};
  ~FrameOwner() { std::free(base); std::free(gain); }
};
hyperdr_plane plane(void*& storage, const std::uint8_t* bytes,
    std::uint32_t width, std::uint32_t height, std::uint32_t channels) {
  const auto row = static_cast<std::size_t>(width) * channels * sizeof(float);
  const auto bytes_used = row * height;
  const auto page = static_cast<std::size_t>(getpagesize());
  const auto allocated = ((bytes_used + page - 1) / page) * page;
  if (posix_memalign(&storage, page, allocated)) throw std::bad_alloc();
  std::memcpy(storage, bytes, bytes_used);
  std::memset(static_cast<std::uint8_t*>(storage) + bytes_used, 0, allocated - bytes_used);
  return {storage, allocated, row, width, height, channels, HYPERDR_PLANE_F32};
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
    const auto options = hyperdr::request_options(hyperdr::json::parse(settings_json));
    return hyperdr::look_curve_json(options.gain, samples) + '\n';
  });
}

int hyperdr_frame_layout(const char* frame_json, uint32_t photo_width, uint32_t photo_height,
                         char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    return hyperdr::frame_layout(document(frame_json), photo_width, photo_height);
  });
}

void hyperdr_string_free(char* string) { std::free(string); }
void hyperdr_error_free(hyperdr_error* error) { std::free(error); }

int hyperdr_engine_create(const char* config_json, hyperdr_engine** out, hyperdr_error** error) {
  if (out) *out = nullptr;
  return boundary(error, [&] {
    required(out);
    hyperdr::EngineConfig config;
    if (config_json) {
      const auto doc = document(config_json);
      for (const auto& [key, value] : doc.members()) {
        if (key == "cache_directory") config.cache_directory = hyperdr::path_from_utf8(value.string());
        else if (key == "heic_tile_workers" || key == "memory_budget_bytes") {
          const double n = value.number();
          if (n < 0 || n > 9007199254740991.0 || std::floor(n) != n) throw std::invalid_argument("invalid engine configuration number");
          if (key == "heic_tile_workers") {
            if (n > 4) throw std::invalid_argument("heic_tile_workers must be in [0,4]");
            config.heic_tile_workers = static_cast<unsigned>(n);
          } else config.memory_budget_bytes = static_cast<std::uint64_t>(n);
        } else throw std::invalid_argument("unknown engine configuration: " + key);
      }
    }
    *out = new hyperdr_engine{hyperdr::Engine(config)};
  });
}
void hyperdr_engine_destroy(hyperdr_engine* engine) { delete engine; }
int hyperdr_capabilities(hyperdr_engine* engine, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] { return required(engine).value.capabilities(); });
}
int hyperdr_probe(hyperdr_engine* engine, const char* path, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    if (!path) throw std::invalid_argument("source path is required");
    return required(engine).value.probe(hyperdr::path_from_utf8(path));
  });
}
int hyperdr_raw_metadata(hyperdr_engine* engine, const char* path, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    if (!path) throw std::invalid_argument("source path is required");
    return required(engine).value.raw_metadata(hyperdr::path_from_utf8(path));
  });
}
int hyperdr_normalize_options(const char* edit, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] { return hyperdr::normalize_options(document(edit)); });
}
int hyperdr_command_line(const char* settings, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    hyperdr::json::Writer writer;
    writer.begin_array();
    for (const auto& argument : hyperdr::command_line(document(settings))) writer.element(argument);
    return writer.end_array().take() + '\n';
  });
}
int hyperdr_preview_open(hyperdr_engine* engine, const char* source, const char* sha256,
    hyperdr_preview_session** out, hyperdr_error** error) {
  if (out) *out = nullptr;
  return boundary(error, [&] {
    required(out);
    if (!source) throw std::invalid_argument("source path is required");
    auto session = required(engine).value.preview_open(hyperdr::path_from_utf8(source), sha256 ? sha256 : "");
    *out = new hyperdr_preview_session{std::move(session)};
  });
}
void hyperdr_preview_close(hyperdr_preview_session* session) { delete session; }
int hyperdr_preview_render(hyperdr_preview_session* session, const char* request,
    hyperdr_cancel* cancel, hyperdr_buffer* out, hyperdr_error** error) {
  return buffer_result(out, error, [&] { return render(session, document(request), cancel); });
}
int hyperdr_model_gain(hyperdr_preview_session* session, const char* request,
    hyperdr_cancel* cancel, hyperdr_buffer* out, hyperdr_error** error) {
  return buffer_result(out, error, [&] {
    return required(session).value->model_gain(hyperdr::request_options(document(request)), token(cancel));
  });
}
void hyperdr_buffer_free(hyperdr_buffer* buffer) {
  if (!buffer) return;
  delete static_cast<std::vector<std::uint8_t>*>(buffer->owner);
  *buffer = {};
}
int hyperdr_preview_render_frame(hyperdr_preview_session* session, const char* request,
    hyperdr_cancel* cancel, hyperdr_frame* out, hyperdr_error** error) {
  if (out) *out = {};
  return boundary(error, [&] {
    required(out);
    const auto doc = document(request);
    auto pixels = required(session).value->render_pixels(hyperdr::request_options(doc),
        hyperdr::request_region(doc), token(cancel), compact(doc));
    auto owner = std::make_unique<FrameOwner>();
    owner->metadata = std::move(pixels.metadata);
    const auto aligned = [](void*& storage, const hyperdr::FloatImage& image) {
      return plane(storage, reinterpret_cast<const std::uint8_t*>(image.pixels.data()),
                   image.width, image.height, image.channels);
    };
    const auto base_plane = aligned(owner->base, pixels.base);
    const auto gain_plane = aligned(owner->gain, pixels.gain);
    if (cancel) cancel->value.check();
    *out = {owner->metadata.c_str(), base_plane, gain_plane, owner.get()};
    owner.release();
  });
}
void hyperdr_frame_free(hyperdr_frame* frame) {
  if (!frame) return;
  delete static_cast<FrameOwner*>(frame->owner);
  *frame = {};
}
int hyperdr_convert(hyperdr_engine* engine, const char* request, hyperdr_event_fn callback,
    void* user, hyperdr_cancel* cancel, char** out, hyperdr_error** error) {
  return json_result(out, error, [&] {
    struct Sink : hyperdr::ProgressSink {
      hyperdr_event_fn callback;
      void* user;
      void on_progress(const hyperdr::ProgressEvent& event) override {
        if (!callback) return;
        hyperdr::json::Writer writer;
        writer.begin_object().member("phase", event.phase).member("path", event.path)
            .member("fraction", event.fraction).member("text", event.text).end_object();
        const auto json = writer.take();
        callback(user, json.c_str());
      }
    } sink;
    sink.callback = callback; sink.user = user;
    return required(engine).value.convert(hyperdr::request_options(document(request)), &sink, token(cancel));
  });
}
hyperdr_cancel* hyperdr_cancel_create(void) { return new (std::nothrow) hyperdr_cancel; }
void hyperdr_cancel_request(hyperdr_cancel* cancel) { if (cancel) cancel->value.request(); }
void hyperdr_cancel_destroy(hyperdr_cancel* cancel) { delete cancel; }

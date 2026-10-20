#include "hyperdr/hyperdr.h"

#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <unistd.h>
#include <memory>
#include <vector>
#include "hyperdr/foundation/version.hpp"

#include <cstdlib>
#include <cmath>
#include <cstring>
#include <new>
#include <stdexcept>
#include <string>

struct hyperdr_engine { hyperdr::Engine value; };
struct hyperdr_cancel { hyperdr::CancelToken value; };

namespace {

void set_error(hyperdr_error** out, const char* code, const char* message, const char* detail_json=nullptr) noexcept {
  if (out == nullptr) return;
  const auto size = std::strlen(message) + 1;
  auto* error = static_cast<hyperdr_error*>(std::malloc(sizeof(hyperdr_error) + size + (detail_json ? std::strlen(detail_json)+1 : 0)));
  if (error == nullptr) return;
  auto* text = reinterpret_cast<char*>(error + 1);
  std::memcpy(text, message, size);
  error->code = code;
  error->message = text;
  error->detail_json = nullptr;
  if(detail_json) {
    std::memcpy(text+size,detail_json,std::strlen(detail_json)+1);
    error->detail_json=text+size;
  }
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
  } catch (const hyperdr::PackageCallbackFailed& exception) {
    set_error(error, "callback_failed", exception.what());

  } catch (const hyperdr::RawUnsupported& exception) {
    try {
      const auto detail = exception.detail_json();
      set_error(error, "raw_unsupported", exception.what(), detail.c_str());
    } catch (...) {
      set_error(error, "out_of_memory", "cannot allocate native error detail");
    }
  } catch (const hyperdr::RawMemoryError& exception) {
    set_error(error, "raw_budget", exception.what());
  } catch (const hyperdr::SourceUnreadable& exception) {
    set_error(error, "source_unreadable", exception.what());
  } catch (const hyperdr::UnsupportedFormat& exception) {
    try {
      const auto detail=exception.detail_json();
      set_error(error,"unsupported_format",exception.what(),detail.empty()?nullptr:detail.c_str());
    } catch (...) { set_error(error,"out_of_memory","cannot allocate native error detail"); }
  } catch (const hyperdr::ExportDimensionLimit& exception) {
    set_error(error, "export_dimension_limit", exception.what());
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
}  // namespace

uint32_t hyperdr_abi_version(void) { return HYPERDR_ABI_VERSION; }
const char* hyperdr_version(void) { return hyperdr::kVersion; }

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
        else if (key == "hevc_override") config.hevc_override = value.string();
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
namespace {

hyperdr::PackagePlane package_plane(const hyperdr_package_plane& plane, const char* what, bool streaming = false) {
  if (!streaming && plane.data == nullptr) throw std::invalid_argument(std::string(what) + " plane data is null");
  if (plane.format != HYPERDR_PLANE_F32)
    throw std::invalid_argument(std::string(what) + " plane must use HYPERDR_PLANE_F32");
  return {static_cast<const float*>(plane.data), plane.row_bytes, plane.size, plane.width,
          plane.height, plane.channels};
}

}  // namespace

namespace {
hyperdr::PackageRequest package_request(const hyperdr_package_request* configuration,
    hyperdr::PackagePlane& sdr,hyperdr::PackageGain& gain,bool streaming) {
    if (configuration == nullptr) throw std::invalid_argument("package request is required");
    hyperdr::PackageRequest request;
    if (configuration->output_path == nullptr) throw std::invalid_argument("package output path is required");
    request.output = hyperdr::path_from_utf8(configuration->output_path);
    const std::string_view format = configuration->format ? configuration->format : "";
    const auto encoding = hyperdr::hdr_encoding_from_name(format);
    if (!encoding) throw std::invalid_argument("unknown output format: \"" + std::string(format) + "\"");
    request.encoding = *encoding;
    if (configuration->parameters_json) {
      const auto parameters = hyperdr::json::parse(configuration->parameters_json);
      if (!parameters.is_object()) throw std::invalid_argument("package parameters must be an object");
      for (const auto& [key, value] : parameters.members()) {
        if (key == "quality") {
          const double n = value.number();
          if (n < 0 || n > 100 || std::floor(n) != n) throw std::invalid_argument("quality must be in [0,100]");
          request.quality = static_cast<int>(n);
        } else if (key == "depth") {
          const double n = value.number();
          if (n != 8 && n != 10) throw std::invalid_argument("depth must be 8 or 10");
          request.depth = static_cast<int>(n);
        } else if (key == "gamut") {
          const auto gamut = hyperdr::color_gamut_from_name(value.string());
          if (!gamut || *gamut == hyperdr::ColorGamut::kRec2020)
            throw std::invalid_argument("gamut must be \"srgb\" or \"p3\"");
          request.gamut = *gamut;
        } else if (key == "verify") request.verify = value.boolean();
        else if (key == "overwrite") request.overwrite = value.boolean();
        else throw std::invalid_argument("unknown package parameter: " + key);
      }
    }
    if (configuration->sdr) {
      sdr = package_plane(*configuration->sdr, "SDR base",streaming);
      request.sdr = &sdr;
    }
    if (configuration->gain) {
      gain.plane = package_plane(configuration->gain->plane, "gain",streaming);
      for (unsigned c = 0; c < 3; ++c) {
        gain.base_offset[c] = configuration->gain->base_offset[c];
        gain.alternate_offset[c] = configuration->gain->alternate_offset[c];
      }
      gain.base_headroom = configuration->gain->base_headroom;
      gain.alternate_headroom = configuration->gain->alternate_headroom;
      if (configuration->gain->working_gamut) gain.working_gamut = configuration->gain->working_gamut;
      request.gain = &gain;
    }
    if (configuration->exif && configuration->exif_size) {
      request.exif = static_cast<const std::uint8_t*>(configuration->exif);
      request.exif_size = configuration->exif_size;
    }
    request.presentation_frame = configuration->presentation_frame != 0;
    if (configuration->has_frame_photo) {
      const auto& rect = configuration->frame_photo;
      request.frame_photo = hyperdr::FrameRect{rect.x, rect.y, rect.width, rect.height};
    }
    return request;
}
}
int hyperdr_package(hyperdr_engine* engine, const hyperdr_package_request* configuration,
    char** out, hyperdr_error** error) {
  return json_result(out,error,[&] {
    hyperdr::PackagePlane sdr;hyperdr::PackageGain gain;
    const auto request=package_request(configuration,sdr,gain,false);
    return required(engine).value.package(request,token(configuration->cancel));
  });
}
int hyperdr_package_rows_supported(const char* format) {
  const auto encoding=hyperdr::hdr_encoding_from_name(format?format:"");
  return encoding&&hyperdr::package_rows_supported(*encoding)?1:0;
}
int hyperdr_package_rows(hyperdr_engine* engine,const hyperdr_package_request* configuration,
    uint32_t rows,hyperdr_package_row_callback callback,void* user,char** out,hyperdr_error** error) {
  return json_result(out,error,[&] {
    if(!callback)throw std::invalid_argument("package row callback is required");
    hyperdr::PackagePlane sdr;hyperdr::PackageGain gain;
    const auto request=package_request(configuration,sdr,gain,true);
    return required(engine).value.package_rows(request,rows,[&](auto y,auto count,auto base,auto auxiliary) {
      if(callback(user,y,count,base.data(),auxiliary.empty()?nullptr:auxiliary.data())) {
        if(const auto cancel=token(configuration->cancel))cancel->check();
        throw hyperdr::PackageCallbackFailed();
      }
    },token(configuration->cancel));
  });
}

hyperdr_cancel* hyperdr_cancel_create(void) { return new (std::nothrow) hyperdr_cancel; }
void hyperdr_cancel_request(hyperdr_cancel* cancel) { if (cancel) cancel->value.request(); }
void hyperdr_cancel_destroy(hyperdr_cancel* cancel) { delete cancel; }

#ifndef HYPERDR_H
#define HYPERDR_H

#include <stdint.h>
#include <stddef.h>

#if defined(_WIN32) && defined(HYPERDR_SHARED)
#  ifdef HYPERDR_CAPI_BUILD
#    define HYPERDR_API __declspec(dllexport)
#  else
#    define HYPERDR_API __declspec(dllimport)
#  endif
#elif defined(__GNUC__)
#  define HYPERDR_API __attribute__((visibility("default")))
#else
#  define HYPERDR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define HYPERDR_ABI_VERSION 1

typedef struct hyperdr_error {
  const char* code;
  const char* message;
} hyperdr_error;

/* Version strings have static lifetime and must not be freed. */
HYPERDR_API uint32_t hyperdr_abi_version(void);
HYPERDR_API const char* hyperdr_version(void);

/* All strings are UTF-8. Calls return 0 on success, nonzero on error.
 * Output strings and errors belong to the library; use the matching free.
 * On failure *out is NULL; *err is set when supplied (may be NULL on OOM).
 * Independent calls may run concurrently. No exceptions cross this boundary.
 */
HYPERDR_API int hyperdr_schema_json(char** out, hyperdr_error** err);
/* settings_json is a strict settings object using the schema's keys.
 * samples has the same [2,4096] range as CLI --samples. Both JSON functions
 * include the CLI's trailing newline for byte-for-byte stream comparison.
 */
HYPERDR_API int hyperdr_curve_json(const char* settings_json, unsigned samples,
                                 char** out, hyperdr_error** err);
/* Pixel layout of a presentation frame (hyperdr.frame/v1 JSON) around a photo
 * of the given oriented size: canvas, photo and caption-band rectangles. Pure
 * and byte-identical to CLI frame-layout. Apps lay out their preview and size
 * the caption overlay with it; convert recomputes it from the rendered photo. */
HYPERDR_API int hyperdr_frame_layout(const char* frame_json, uint32_t photo_width,
                                     uint32_t photo_height, char** out, hyperdr_error** err);
HYPERDR_API void hyperdr_string_free(char* string);
HYPERDR_API void hyperdr_error_free(hyperdr_error* error);

/* Handles may be destroyed after their synchronous calls return. Cancellation
 * request is safe from another thread. A preview session accepts one call at a
 * time (busy otherwise); separate sessions may run concurrently. Sessions and
 * returned buffers/frames can outlive their engine. Free each result exactly
 * once, using this library. Callbacks run on the calling thread and must not
 * throw, destroy active handles, or reenter their preview session. */
typedef struct hyperdr_engine hyperdr_engine;
typedef struct hyperdr_preview_session hyperdr_preview_session;
typedef struct hyperdr_cancel hyperdr_cancel;
typedef struct hyperdr_buffer {
  const uint8_t* data;
  size_t size;
  void* owner;
} hyperdr_buffer;
typedef void (*hyperdr_event_fn)(void* user, const char* event_json);
enum { HYPERDR_PLANE_F32 = 1, HYPERDR_PLANE_F16 = 2 };
typedef struct hyperdr_plane {
  const void* data; /* Page aligned; tightly packed rows. */
  size_t size; /* Allocation size, rounded up to a page; padding is zero. */
  size_t row_bytes;
  uint32_t width, height, channels, format;
} hyperdr_plane;
typedef struct hyperdr_frame {
  /* v1/v2 sourceWidth/Height are full-resolution, oriented, default-cropped
   * dimensions. v2 baseHeadroom/alternateHeadroom are log2 stops, as used to
   * compute gainWeight from headroomStops (not linear headroom multiples). */
  const char* metadata_json;
  hyperdr_plane base;
  hyperdr_plane gain; /* v2: encoded mono gain; v1: linear P3 HDR RGB. */
  void* owner;
} hyperdr_frame;

/* config: cache_directory (UTF-8), memory_budget_bytes, heic_tile_workers (0..4).
 * Request JSON: canonical settings at the top level; optional `command` holds
 * input/output/report, overwrite/recursive/skip_existing, depth, model_id,
 * external_gain/external_gain_report and region {left,top,width,height,center}.
 * Preview ignores command.input (the session is bound to source_utf8).
 * command.compact defaults true, false matches preview-frame's file output.
 * normalize_options adds `command` to the Python-compatible renderer settings.
 * normalize_options adds command.adapter = "panel-v1". Preserve this marker
 * verbatim when changing command keys. Only panel-v1 requests use the Python
 * panel's three-decimal quantization; untagged canonical requests retain full
 * precision. Unknown adapters are rejected as invalid_options. Normalization
 * and consumption must use the same version of this library.
 * command_line returns a JSON argv array, without shell quoting.
 * preview_open is lazy: decoding happens on the first render/model call.
 * convert returns a completed batch report; inspect per-file success in it.
 * Functions return zero on success, nonzero with a library-owned error on
 * failure. Output fields are cleared on failure. Pass NULL for optional err,
 * config_json, source_sha256, cancel or callback. F32 frames are always supported;
 * F16 is reserved. metadata_json and both planes live until frame_free. */
HYPERDR_API int hyperdr_engine_create(const char* config_json, hyperdr_engine** out, hyperdr_error** err);
HYPERDR_API void hyperdr_engine_destroy(hyperdr_engine*);
HYPERDR_API int hyperdr_capabilities(hyperdr_engine*, char** out_json, hyperdr_error** err);
HYPERDR_API int hyperdr_probe(hyperdr_engine*, const char* path_utf8, char** out_json, hyperdr_error** err);
/* RAW capture/lens metadata, byte-identical to CLI raw-metadata (trailing newline).
 * Decoding calls distinguish source_unreadable, unsupported_format and decode_failed. */
HYPERDR_API int hyperdr_raw_metadata(hyperdr_engine*, const char* path_utf8, char** out_json, hyperdr_error** err);
HYPERDR_API int hyperdr_normalize_options(const char* edit_options_json, char** settings_json, hyperdr_error** err);
HYPERDR_API int hyperdr_command_line(const char* settings_json, char** out, hyperdr_error** err);
HYPERDR_API int hyperdr_preview_open(hyperdr_engine*, const char* source_utf8, const char* source_sha256,
    hyperdr_preview_session** out, hyperdr_error** err);
HYPERDR_API void hyperdr_preview_close(hyperdr_preview_session*);
HYPERDR_API int hyperdr_preview_render(hyperdr_preview_session*, const char* request_json,
    hyperdr_cancel*, hyperdr_buffer*, hyperdr_error**);
HYPERDR_API int hyperdr_preview_render_frame(hyperdr_preview_session*, const char* request_json,
    hyperdr_cancel*, hyperdr_frame*, hyperdr_error**);
HYPERDR_API void hyperdr_frame_free(hyperdr_frame*);
HYPERDR_API int hyperdr_model_gain(hyperdr_preview_session*, const char* request_json,
    hyperdr_cancel*, hyperdr_buffer*, hyperdr_error**);
HYPERDR_API int hyperdr_convert(hyperdr_engine*, const char* request_json,
    hyperdr_event_fn, void* user, hyperdr_cancel*, char** out_report_json, hyperdr_error**);
HYPERDR_API hyperdr_cancel* hyperdr_cancel_create(void);
HYPERDR_API void hyperdr_cancel_request(hyperdr_cancel*);
HYPERDR_API void hyperdr_cancel_destroy(hyperdr_cancel*);
HYPERDR_API void hyperdr_buffer_free(hyperdr_buffer*);

#ifdef __cplusplus
}
#endif

#endif

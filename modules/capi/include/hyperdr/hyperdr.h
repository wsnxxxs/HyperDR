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

#define HYPERDR_ABI_VERSION 4

typedef struct hyperdr_error {
  const char* code;
  const char* message;
  /* Optional JSON object, owned by this error. Shape is fixed by error code:
   * raw_unsupported: {"container":"dng"|"camera","model":"<UTF-8 text or empty>"}.
   * NULL for errors without a defined structured detail. */
  const char* detail_json;
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

/* config: cache_directory (UTF-8), memory_budget_bytes, heic_tile_workers (0..4),
 * hevc_override (test-only: "unavailable" or "no-main10"; absent = real probe).
 * memory_budget_bytes sizes decoded output and export estimates: a decode that
 * would exceed it is reduced. A single coded HEVC picture (one tile, or an
 * untiled image) is not bounded by it, only by the fixed raster geometry limit.
 * capabilities.memoryBudgetBytes echoes this setting; effectiveMemoryBudgetBytes is
 * the limit an export is checked against (the setting, or the host's memory less
 * a 512 MiB reserve when it is 0). 0 is unlimited only when the host could not
 * report its memory and none is set; on a host with less than 512 MiB it is a
 * real limit of 0, and every export is refused.
 * capabilities.encoder reports backend, main8/main10, state and reason.
 * HEVC failures use existing per-file error_code: hevc_unavailable,
 * hevc_main10_unavailable or hevc_probe_failed. A requested 10-bit export
 * never falls back to 8-bit; completed reports retain schema 13.
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
 * A JPEG dimension failure has per-file error_code=export_dimension_limit,
 * with detail describing actual dimensions and the 65500 per-side limit. So
 * does an AVIF canvas (photo plus frame) past what libavif can decode, more
 * than 16384x16384 pixels or 32768 on a side; the detail gives both limits and
 * the size, and nothing is encoded.
 * Functions return zero on success, nonzero with a library-owned error on
 * failure. Output fields are cleared on failure. Pass NULL for optional err,
 * config_json, source_sha256, cancel or callback. F32 frames are always supported;
 * F16 is reserved. metadata_json and both planes live until frame_free. */
HYPERDR_API int hyperdr_engine_create(const char* config_json, hyperdr_engine** out, hyperdr_error** err);
HYPERDR_API void hyperdr_engine_destroy(hyperdr_engine*);
HYPERDR_API int hyperdr_capabilities(hyperdr_engine*, char** out_json, hyperdr_error** err);
HYPERDR_API int hyperdr_probe(hyperdr_engine*, const char* path_utf8, char** out_json, hyperdr_error** err);
/* RAW capture/lens metadata, byte-identical to CLI raw-metadata (trailing newline).
 * Decoding calls distinguish source_unreadable, unsupported_format, raw_unsupported and decode_failed. */
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

/* --- packaging --------------------------------------------------------------
 * The P7 GPU render graph renders in Swift, so the engine's export entry point
 * is a writer rather than a converter: it takes the finished planes, quantizes
 * and dithers the gain codes, writes the container with the same encoders
 * `hyperdr_convert` uses, verifies the file by decoding it, and reports what it
 * wrote. Format, quality and depth mean exactly what they mean in a convert
 * request; nothing is graded, cropped or resized here.
 *
 * Input contract (docs/architecture/gpu-pipeline.md §3):
 * - SDR base: linear extended Display P3, D65, SDR white = 1.0. Three
 *   interleaved float32 channels. Values above 1 and below 0 are allowed; every
 *   sample must be finite. Half precision is not accepted: the writers allocate
 *   float images anyway, so a caller converting from half loses nothing.
 * - Gain plane: log2 stops over the base's SDR white, one or three interleaved
 *   float32 channels, at the same pixel grid as the base (this version stores
 *   the codes 1:1). One channel means the same multiplier applies to RGB.
 * - ISO 21496-1 parameters travel verbatim: per-channel base and alternate
 *   offsets in SDR-white-relative units, base and alternate headroom in log2
 *   stops, and the gain working gamut. Only "display-p3" (the base's own
 *   space) is accepted, because no writer converts a grid between gamuts.
 * - Gain is stored by "adaptive" (one channel) and "iso-gainmap-jpeg" (one or
 *   three). The BT.2100 formats ("pq", "hlg", "avif-pq", "avif-hlg")
 *   reconstruct an HDR rendition from the pair and store no gain map. The SDR
 *   formats ("sdr-jpeg", "sdr-tiff") store none and ignore the gain plane.
 *   A combination a writer cannot represent is refused with the
 *   "unsupported_format" code rather than being approximated.
 *   "adaptive" writes ISO 21496-1's Apple form, which declares alternate
 *   headroom equal to the map's largest gain: a positive alternate_headroom is
 *   used as that declared capacity, and a gain above it is refused. Zero or
 *   negative means "declare the plane's own maximum". That form stores no
 *   signed gain, so a negative gain (an HDR pixel below its SDR base) is
 *   clipped to zero there, exactly as the converter's Adaptive exports do; the
 *   number of clipped samples is reported.
 *   The BT.2100 formats reconstruct the rendition at the declared headroom, so
 *   HLG's ~2.3-stop ceiling is enforced exactly as it is for a convert, and a
 *   canvas past JPEG's 65500 per side or libavif's decode limits fails with the
 *   same export_dimension_limit code.
 * - Exif travels as a serialized block from the source file; the writer
 *   re-emits the safe portable subset (as an export always has). Orientation is
 *   written as 1, because the planes are expected upright. There is no ICC
 *   input: the base space is fixed by this contract, so each writer stores the
 *   profile for it.
 * - Whole planes only. A banded, row-callback form for iPhone memory limits is
 *   deliberately not invented yet: it arrives with P7-3's chunked export, and
 *   this struct grows then. TODO(P7-3): chunked input.
 *
 * The report (hyperdr.package/v1) states the format, size, byte count, the
 * verification performed, and the gain parameters actually written (not the
 * ones requested); "gain": null means the format stored none, and
 * "gain.stored": false means the gain only fed a BT.2100 rendition. Its
 * metadata.exif says whether a source Exif block was carried; the writers
 * always emit a minimal block of their own. Both planes are read once, during
 * the call, so the caller may release them when it returns.
 */
typedef struct hyperdr_package_plane {
  /* Tightly packed rows of `width * channels` float32 samples, or rows at
   * `row_bytes` when that is non-zero. */
  const void* data;
  size_t row_bytes;
  /* Bytes `data` really holds. Zero means "the rows are complete"; a non-zero
   * value must cover `row_bytes * height`, so an undersized buffer is refused
   * instead of read past its end. */
  size_t size;
  uint32_t width, height, channels;
  uint32_t format; /* HYPERDR_PLANE_F32 */
} hyperdr_package_plane;

typedef struct hyperdr_package_gain {
  hyperdr_package_plane plane;
  /* Per channel; only [0] is used for a one-channel map. */
  float base_offset[3];
  float alternate_offset[3];
  float base_headroom;      /* log2 stops */
  float alternate_headroom; /* log2 stops */
  /* UTF-8; NULL means "display-p3". */
  const char* working_gamut;
} hyperdr_package_gain;

typedef struct hyperdr_package_rect {
  uint32_t x, y, width, height; /* pixels inside the SDR base */
} hyperdr_package_rect;

typedef struct hyperdr_package_request {
  const char* output_path;    /* UTF-8; required */
  const char* format;         /* UTF-8 canonical name; required */
  /* Optional JSON object: quality (0..100), depth (8 or 10, Adaptive base),
   * hevc_preset ("slow" or "medium"), gamut ("srgb" or "p3", SDR output
   * only), verify (default true), overwrite (default false). Unknown keys are
   * rejected as invalid_options. */
  const char* parameters_json;
  const hyperdr_package_plane* sdr; /* required */
  const hyperdr_package_gain* gain; /* optional */
  const void* exif;                 /* optional serialized Exif block */
  size_t exif_size;
  /* Non-zero when the planes already carry the presentation frame, because the
   * GPU graph composites the mat before packaging. E5 then applies here too:
   * the gain codebook keeps an exact zero-gain code at gamma 1, the mat's zero
   * samples land on it, and the writer is told the map belongs to a framed
   * canvas. It also requires equal base and alternate offsets. */
  int presentation_frame;
  /* Photograph rectangle, selected by has_frame_photo. Asks for the E5 readback
   * as well: the written file is decoded and every mat pixel outside this
   * rectangle must carry no gain. Costs one extra decode and needs a format
   * that stores a gain map; the rectangle must lie inside the SDR base. */
  int has_frame_photo;
  hyperdr_package_rect frame_photo;
  hyperdr_cancel* cancel;           /* optional */
} hyperdr_package_request;

/* Runs on the calling thread and honours the cancel token between stages. The
 * report belongs to the library; free it with hyperdr_string_free. */
HYPERDR_API int hyperdr_package(hyperdr_engine*, const hyperdr_package_request* request,
                                char** out_report_json, hyperdr_error** err);

#ifdef __cplusplus
}
#endif

#endif

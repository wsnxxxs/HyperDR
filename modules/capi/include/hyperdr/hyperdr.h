#ifndef HYPERDR_H
#define HYPERDR_H

#include <stdint.h>
#include <stddef.h>

#if defined(__GNUC__)
# define HYPERDR_API __attribute__((visibility("default")))
#else
# define HYPERDR_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define HYPERDR_ABI_VERSION 6

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
/* Pure presentation-frame layout for an upright photograph. */
HYPERDR_API int hyperdr_frame_layout(const char* frame_json, uint32_t photo_width,
                                     uint32_t photo_height, char** out, hyperdr_error** err);
HYPERDR_API void hyperdr_string_free(char* string);
HYPERDR_API void hyperdr_error_free(hyperdr_error* error);

/* Synchronous calls may run concurrently on independent handles. Cancellation
 * requests are safe from another thread. Destroy handles after calls return. */
typedef struct hyperdr_engine hyperdr_engine;
typedef struct hyperdr_cancel hyperdr_cancel;
enum { HYPERDR_PLANE_F32 = 1 };
/* config: cache_directory, memory_budget_bytes, heic_tile_workers (0..4),
 * hevc_override (test only: unavailable/no-main10). Unknown keys are rejected. */
HYPERDR_API int hyperdr_engine_create(const char*, hyperdr_engine**, hyperdr_error**);
HYPERDR_API void hyperdr_engine_destroy(hyperdr_engine*);
HYPERDR_API int hyperdr_capabilities(hyperdr_engine*, char**, hyperdr_error**);
HYPERDR_API int hyperdr_probe(hyperdr_engine*, const char*, char**, hyperdr_error**);
HYPERDR_API hyperdr_cancel* hyperdr_cancel_create(void);
HYPERDR_API void hyperdr_cancel_request(hyperdr_cancel*);
HYPERDR_API void hyperdr_cancel_destroy(hyperdr_cancel*);

/* --- RAW compatibility (ABI 6) ---------------------------------------------
 * For camera RAW files the system RAW engine cannot develop. LibRaw only
 * unpacks sensor data and metadata (Bayer data is not demosaiced); the result
 * is a DNG the system develops like any other DNG. Output files are created
 * exclusively and published atomically.
 * Static stable id of this converter, e.g. "libraw-0.22.0/dng-1". It changes
 * whenever the DNG written for the same input could change. */
HYPERDR_API const char* hyperdr_raw_converter_id(void);
/* report JSON: {"converter":id,"layout":"cfa"|"linear","make":s,"model":s,
 *   "width":n,"height":n (default crop, before orientation),"orientation":1..8}
 * Errors: raw_unsupported (detail_json {"container":"camera","model":...}) when
 * LibRaw cannot read the file or has no colour matrix; plus the existing
 * cancellation / I/O codes. */
HYPERDR_API int hyperdr_raw_convert_dng(hyperdr_engine*, const char* raw_path, const char* dng_path,
                                        hyperdr_cancel*, char** report, hyperdr_error**);
/* Writes the largest embedded JPEG preview, unchanged, to jpeg_path.
 * report: {"width":n,"height":n,"orientation":1..8}. Errors: no_preview when
 * the file has no JPEG preview; raw_unsupported; cancellation / I/O. */
HYPERDR_API int hyperdr_raw_extract_preview(hyperdr_engine*, const char* raw_path, const char* jpeg_path,
                                            hyperdr_cancel*, char** report, hyperdr_error**);

/* --- packaging --------------------------------------------------------------
 * The P7 GPU render graph renders in Swift, so the engine's export entry point
 * is a writer rather than a converter: it takes the finished planes, quantizes
 * and dithers the gain codes, writes the native container, verifies the file by decoding it, and reports what it
 * wrote. Nothing is graded, cropped or resized here.
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
 *   clipped to zero there; the
 *   number of clipped samples is reported.
 *   The BT.2100 formats reconstruct the rendition at the declared headroom, so
 *   HLG's ~2.3-stop ceiling is enforced, and a
 *   canvas past JPEG's 65500 per side or libavif's decode limits fails with the
 *   same export_dimension_limit code.
 * - Exif travels as a serialized block from the source file; the writer
 *   re-emits the safe portable subset (as an export always has). Orientation is
 *   written as 1, because the planes are expected upright. There is no ICC
 *   input: the base space is fixed by this contract, so each writer stores the
 *   profile for it.
 * - This entry consumes whole planes. See hyperdr_package_rows for the
 *   additive single-pass row-callback entry.
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
   * gamut ("srgb" or "p3", SDR output
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

/* Row entry points introduced in ABI 4; retained unchanged in ABI 5.
 * Supported: SDR JPEG/TIFF, ISO gain-map JPEG, Adaptive/PQ/HLG HEIC,
 * and PQ/HLG AVIF. AVIF stages 10-bit RGB (6 bytes/canvas pixel) and compressed
 * AV1 samples on disk beside the output. At most one 1024x1024 4:4:4 cell and
 * one encoder context (up to 4 threads) are resident beside a cell verifier.
 * AVIF cells are independently predicted, so bytes/codes may differ at seams.
 * JPEG uses fixed Huffman tables to avoid a whole-frame coefficient store:
 * entropy bytes differ from whole-plane, decoded codes do not. TIFF uses strips.
 * HEIC assembles 512-row slabs and spools compressed samples to disk.
 * HDR rows first spool the exact float32 base/gain pair (16 or 24 B/pixel)
 * into an anonymous, uncached file; no image-sized RAM cache is retained.
 * Verification is bounded for JPEG, TIFF, HEIC and row-written AVIF grids.
 * This query describes compiled paths, not runtime HEVC device availability. */
HYPERDR_API int hyperdr_package_rows_supported(const char* format);
/* Fill caller-provided, tightly packed float32 buffers: count*width*3 base
 * values and count*width*gain_channels gain values (NULL when there is no gain).
 * Called synchronously, serially, on the package thread. Buffers are borrowed
 * only inside the callback. Each band is requested once, in ascending order;
 * HDR statistics and encoding share the library's disk replay. Return 0 on
 * success, nonzero to abort (callback_failed, or cancelled
 * when the cancel token is set). Never call another engine operation here. */
typedef int (*hyperdr_package_row_callback)(void* user, uint32_t y, uint32_t count,
                                           float* base, float* gain);
/* request.sdr / request.gain supply full dimensions/channels and metadata;
 * their plane data/size/row_bytes are ignored, format must be F32. rows is
 * 1..4096 (256 recommended). No caller planes are retained. The request, its
 * strings and callback context stay alive for this call. Stages and errors,
 * E5 staging/readback, cancellation and report match hyperdr_package.
 * ENOSPC/EDQUOT are reported as insufficient_storage (additive in ABI 5). */
HYPERDR_API int hyperdr_package_rows(hyperdr_engine*, const hyperdr_package_request*,
    uint32_t rows, hyperdr_package_row_callback, void* user,
    char** out_report_json, hyperdr_error** err);

/* Additive in ABI 5: hyperdr_package_rows plus a progress callback for the
 * writer's independent units after the rows are read. PQ/HLG AVIF reports each
 * grid cell as it is encoded (HYPERDR_PACKAGE_PHASE_ENCODE) and as it is
 * verified (HYPERDR_PACKAGE_PHASE_VERIFY); its cells are verified on a second
 * thread while the next one encodes. Other formats report nothing. `done`
 * never decreases within a phase and reaches `total`. Called synchronously on
 * the package thread with the same `user`; it must return quickly and never
 * call another engine operation. `progress` may be NULL. */
#define HYPERDR_PACKAGE_PHASE_ENCODE 1u
#define HYPERDR_PACKAGE_PHASE_VERIFY 2u
typedef void (*hyperdr_package_progress_callback)(void* user, uint32_t phase, uint32_t done, uint32_t total);
HYPERDR_API int hyperdr_package_rows_progress(hyperdr_engine*, const hyperdr_package_request*,
    uint32_t rows, hyperdr_package_row_callback, hyperdr_package_progress_callback progress, void* user,
    char** out_report_json, hyperdr_error** err);

#ifdef __cplusplus
}
#endif

#endif

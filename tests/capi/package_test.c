/* The packaging entry point: synthetic planes in, a written file out.
 *
 * The engine no longer renders for export after P7 (docs/architecture/
 * gpu-pipeline.md §3): it takes the SDR base and gain plane the GPU graph
 * produced, quantizes the gain, writes the container and verifies it. This test
 * covers the parts of that contract a caller depends on: a gain-map format
 * stores the pair and reads back as a gain-map photo, an SDR format writes no
 * gain at all, and a pair a writer cannot represent is refused by error code
 * instead of being approximated. */

#include "hyperdr/hyperdr.h"

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define REQUIRE(condition) do { \
  if (!(condition)) { fprintf(stderr, "failed at line %d: %s\n", __LINE__, #condition); return 1; } \
} while (0)

#define WIDTH 48
#define HEIGHT 32

static float base_samples[WIDTH * HEIGHT * 3];
static float gain_samples[WIDTH * HEIGHT];
static float rgb_gain_samples[WIDTH * HEIGHT * 3];
static float framed_base[WIDTH * HEIGHT * 3];
static float framed_gain[WIDTH * HEIGHT];

/* The photograph sits at this rectangle; everything around it is mat. The mat
 * is wider than one coding block, so the decoded readback has pixels of its own
 * to check away from the photo's edge. */
#define PHOTO_X 12
#define PHOTO_Y 10
#define PHOTO_W 24
#define PHOTO_H 12

/* A gradient rather than flat colour, with a bright corner so the gain map
 * carries a real range: 0 stops at the dark corner, 2 stops at the bright one. */
static void fill(void) {
  for (int y = 0; y < HEIGHT; ++y) {
    for (int x = 0; x < WIDTH; ++x) {
      const size_t pixel = (size_t)y * WIDTH + (size_t)x;
      const float u = (float)x / (WIDTH - 1), v = (float)y / (HEIGHT - 1);
      base_samples[pixel * 3 + 0] = 0.05f + 0.80f * u;
      base_samples[pixel * 3 + 1] = 0.05f + 0.70f * v;
      base_samples[pixel * 3 + 2] = 0.05f + 0.60f * (1.0f - u) * (1.0f - v);
      const float stops = 2.0f * u * v;
      gain_samples[pixel] = stops;
      rgb_gain_samples[pixel * 3 + 0] = stops * (0.6f + 0.4f * v);
      rgb_gain_samples[pixel * 3 + 1] = stops;
      rgb_gain_samples[pixel * 3 + 2] = 0.5f * stops;
    }
  }
}

static hyperdr_package_plane plane(const void* data, uint32_t channels) {
  hyperdr_package_plane value;
  memset(&value, 0, sizeof(value));
  value.data = data;
  value.row_bytes = (size_t)WIDTH * channels * sizeof(float);
  value.size = value.row_bytes * HEIGHT;
  value.width = WIDTH;
  value.height = HEIGHT;
  value.channels = channels;
  value.format = HYPERDR_PLANE_F32;
  return value;
}

/* A framed canvas: a flat mat with exactly zero gain, and a photograph inside
 * it that reaches both above and below its own base, so the codebook has to
 * align a zero code between two non-zero endpoints. */
static void fill_framed(void) {
  for (int y = 0; y < HEIGHT; ++y) {
    for (int x = 0; x < WIDTH; ++x) {
      const size_t pixel = (size_t)y * WIDTH + (size_t)x;
      const int inside = x >= PHOTO_X && x < PHOTO_X + PHOTO_W &&
                         y >= PHOTO_Y && y < PHOTO_Y + PHOTO_H;
      if (!inside) {
        framed_base[pixel * 3 + 0] = 0.18f;
        framed_base[pixel * 3 + 1] = 0.18f;
        framed_base[pixel * 3 + 2] = 0.18f;
        framed_gain[pixel] = 0.0f;
        continue;
      }
      const float u = (float)(x - PHOTO_X) / (PHOTO_W - 1);
      const float v = (float)(y - PHOTO_Y) / (PHOTO_H - 1);
      framed_base[pixel * 3 + 0] = 0.05f + 0.80f * u;
      framed_base[pixel * 3 + 1] = 0.05f + 0.70f * v;
      framed_base[pixel * 3 + 2] = 0.10f;
      framed_gain[pixel] = -0.4f + 2.8f * u * v;
    }
  }
}

static hyperdr_package_gain mono_gain(void) {
  hyperdr_package_gain value;
  memset(&value, 0, sizeof(value));
  value.plane = plane(gain_samples, 1);
  value.alternate_headroom = 2.0f;
  value.working_gamut = "display-p3";
  return value;
}

static hyperdr_package_gain rgb_gain(void) {
  hyperdr_package_gain value;
  memset(&value, 0, sizeof(value));
  value.plane = plane(rgb_gain_samples, 3);
  for (unsigned c = 0; c < 3; ++c) {
    value.base_offset[c] = 1.0f / 64.0f;
    value.alternate_offset[c] = 1.0f / 64.0f;
  }
  value.alternate_headroom = 2.0f;
  value.working_gamut = "display-p3";
  return value;
}

static int contains(const char* text, const char* needle) {
  return text != NULL && strstr(text, needle) != NULL;
}

/* The whole file, so a failed export can be checked against what was there. */
static unsigned char* read_all(const char* path, size_t* size) {
  FILE* file = fopen(path, "rb");
  if (file == NULL) return NULL;
  if (fseek(file, 0, SEEK_END) != 0) { fclose(file); return NULL; }
  const long length = ftell(file);
  if (length < 0) { fclose(file); return NULL; }
  rewind(file);
  unsigned char* bytes = (unsigned char*)malloc((size_t)length);
  if (bytes != NULL && fread(bytes, 1, (size_t)length, file) != (size_t)length) {
    free(bytes);
    bytes = NULL;
  }
  fclose(file);
  if (bytes != NULL) *size = (size_t)length;
  return bytes;
}

/* Directory entries starting with `prefix`: a staged export cleans up after a
 * failure, so a `*.reading.*` file left in the directory is a leak. */
static int count_prefix(const char* directory, const char* prefix) {
  DIR* dir = opendir(directory);
  if (dir == NULL) return -1;
  int count = 0;
  const size_t length = strlen(prefix);
  for (struct dirent* entry = readdir(dir); entry != NULL; entry = readdir(dir))
    if (strncmp(entry->d_name, prefix, length) == 0) ++count;
  closedir(dir);
  return count;
}

static int write_text(const char* path, const char* text) {
  FILE* file = fopen(path, "wb");
  if (file == NULL) return 1;
  const size_t length = strlen(text);
  const int failed = fwrite(text, 1, length, file) != length;
  return fclose(file) != 0 || failed;
}

static int holds_text(const char* path, const char* text) {
  size_t size = 0;
  unsigned char* bytes = read_all(path, &size);
  const size_t length = strlen(text);
  const int same = bytes != NULL && size == length && memcmp(bytes, text, length) == 0;
  free(bytes);
  return same;
}

/* Reads the file back through the engine's own decoder, which is what proves a
 * written container is a photograph and not just bytes on disk. */
static int probed_as(hyperdr_engine* engine, const char* path, const char* domain) {
  hyperdr_error* error = NULL;
  char* output = NULL;
  const int status = hyperdr_probe(engine, path, &output, &error);
  const int ok = status == 0 && contains(output, domain) &&
                 contains(output, "\"width\":48") && contains(output, "\"height\":32");
  if (!ok)
    fprintf(stderr, "probe of %s did not report %s: %s\n", path, domain,
            output != NULL ? output : (error && error->message ? error->message : "no message"));
  hyperdr_error_free(error);
  hyperdr_string_free(output);
  return ok ? 0 : 1;
}

int main(void) {
  REQUIRE(hyperdr_abi_version() == HYPERDR_ABI_VERSION);
  fill();
  char directory[] = "/tmp/hyperdr-package-XXXXXX";
  REQUIRE(mkdtemp(directory) != NULL);
  char gain_path[512], sdr_path[512], refused_path[512];
  snprintf(gain_path, sizeof(gain_path), "%s/iso-gainmap-jpeg.jpg", directory);
  snprintf(sdr_path, sizeof(sdr_path), "%s/sdr-tiff.tif", directory);
  snprintf(refused_path, sizeof(refused_path), "%s/adaptive.heic", directory);

  hyperdr_engine* engine = NULL;
  hyperdr_error* error = NULL;
  REQUIRE(hyperdr_engine_create("{}", &engine, &error) == 0 && engine != NULL);
  hyperdr_error_free(error);
  error = NULL;

  /* A gain-map format with a one-channel plane: the pair must survive the round
   * trip, and the report must state the parameters that were actually written. */
  hyperdr_package_plane base = plane(base_samples, 3);
  hyperdr_package_gain mono = mono_gain();
  hyperdr_package_request write = {0};
  write.output_path = gain_path;
  write.format = "iso-gainmap-jpeg";
  write.parameters_json = "{\"quality\":88}";
  write.sdr = &base;
  write.gain = &mono;
  char* report = NULL;
  REQUIRE(hyperdr_package(engine, &write, &report, &error) == 0 && report != NULL);
  REQUIRE(error == NULL);
  REQUIRE(contains(report, "\"schema\":\"hyperdr.package/v1\""));
  REQUIRE(contains(report, "\"format\":\"iso-gainmap-jpeg\""));
  REQUIRE(contains(report, "\"verified\":true"));
  REQUIRE(contains(report, "\"verification\":\"iso-gainmap-jpeg\""));
  REQUIRE(contains(report, "\"gainMin\":0"));
  REQUIRE(contains(report, "\"gainMax\":2"));
  REQUIRE(contains(report, "\"channels\":1"));
  REQUIRE(contains(report, "\"stored\":true"));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, gain_path, "dual-rendition") == 0);

  /* A three-channel pair is stored as one: the ISO multichannel form. */
  char rgb_path[512];
  snprintf(rgb_path, sizeof(rgb_path), "%s/iso-rgb.jpg", directory);
  hyperdr_package_gain rgb = rgb_gain();
  write.output_path = rgb_path;
  write.gain = &rgb;
  REQUIRE(hyperdr_package(engine, &write, &report, &error) == 0 && report != NULL);
  REQUIRE(contains(report, "\"channels\":3"));
  REQUIRE(contains(report, "\"baseOffsets\":[0.015625,0.015625,0.015625]"));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, rgb_path, "dual-rendition") == 0);

  /* An SDR format stores no gain: the plane is ignored, not written. */
  write.output_path = sdr_path;
  write.format = "sdr-tiff";
  write.parameters_json = "{\"gamut\":\"p3\"}";
  write.gain = NULL;
  REQUIRE(hyperdr_package(engine, &write, &report, &error) == 0 && report != NULL);
  REQUIRE(contains(report, "\"format\":\"sdr-tiff\""));
  REQUIRE(contains(report, "\"verification\":\"sdr-tiff\""));
  REQUIRE(contains(report, "\"gain\":null"));
  REQUIRE(contains(report, "\"icc\":\"display-p3\""));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, sdr_path, "display-referred-sdr") == 0);

  /* Adaptive HEIC is ISO 21496-1's Apple form: one channel, headroom equal to
   * the map's largest gain. A three-channel pair is refused by name. */
  write.output_path = refused_path;
  write.format = "adaptive";
  write.parameters_json = NULL;
  write.gain = &rgb;
  REQUIRE(hyperdr_package(engine, &write, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "unsupported_format") == 0);
  REQUIRE(contains(error->message, "single-channel"));
  hyperdr_error_free(error);
  error = NULL;
  REQUIRE(access(refused_path, F_OK) != 0);

  /* A gain above the declared alternate headroom cannot be stored, so it is
   * refused rather than clipped to the capacity. */
  hyperdr_package_gain understated = mono_gain();
  understated.alternate_headroom = 1.0f;
  write.gain = &understated;
  REQUIRE(hyperdr_package(engine, &write, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "unsupported_format") == 0);
  REQUIRE(contains(error->message, "headroom"));
  hyperdr_error_free(error);
  error = NULL;

  /* The adaptive path itself still works with a one-channel pair. */
  write.gain = &mono;
  write.parameters_json = "{\"depth\":8}";
  REQUIRE(hyperdr_package(engine, &write, &report, &error) == 0 && report != NULL);
  REQUIRE(contains(report, "\"format\":\"adaptive\""));
  REQUIRE(contains(report, "\"verification\":\"heic-gain-map\""));
  REQUIRE(contains(report, "\"alternateHeadroom\":2"));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, refused_path, "dual-rendition") == 0);

  /* A write never replaces an existing file unless it was asked to. */
  REQUIRE(hyperdr_package(engine, &write, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(contains(error->message, "output exists"));
  hyperdr_error_free(error);
  error = NULL;

  /* HLG carries only about 2.3 stops above diffuse white, so a declared
   * headroom past that is refused instead of being compressed behind metadata
   * that still claims it. */
  char hlg_path[512];
  snprintf(hlg_path, sizeof(hlg_path), "%s/hlg.heic", directory);
  hyperdr_package_gain tall = mono_gain();
  tall.alternate_headroom = 3.5f;
  hyperdr_package_request hlg = {0};
  hlg.output_path = hlg_path;
  hlg.format = "hlg";
  hlg.sdr = &base;
  hlg.gain = &tall;
  REQUIRE(hyperdr_package(engine, &hlg, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "invalid_options") == 0);
  REQUIRE(contains(error->message, "2.3"));
  hyperdr_error_free(error);
  error = NULL;
  REQUIRE(access(hlg_path, F_OK) != 0);

  /* A plane whose stated buffer is too short is refused rather than read past
   * its end. */
  hyperdr_package_plane truncated = plane(base_samples, 3);
  truncated.size = 64;
  hyperdr_package_request short_base = write;
  short_base.output_path = hlg_path;
  short_base.format = "sdr-jpeg";
  short_base.gain = NULL;
  short_base.sdr = &truncated;
  REQUIRE(hyperdr_package(engine, &short_base, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "invalid_options") == 0);
  REQUIRE(contains(error->message, "shorter than its rows"));
  hyperdr_error_free(error);
  error = NULL;

  /* A framed canvas (P7): the mat must stay SDR, so the codebook keeps an
   * exact zero-gain code at gamma 1 and the entry point reads its own file back
   * to prove the mat outside the photograph carries no gain. */
  fill_framed();
  char framed_path[512], framed_bad_path[512];
  snprintf(framed_path, sizeof(framed_path), "%s/framed.jpg", directory);
  snprintf(framed_bad_path, sizeof(framed_bad_path), "%s/framed-bad.jpg", directory);
  hyperdr_package_plane framed_base_plane = plane(framed_base, 3);
  hyperdr_package_gain framed = mono_gain();
  framed.plane = plane(framed_gain, 1);
  framed.alternate_headroom = 2.8f;
  hyperdr_package_request framed_ok = {0};
  framed_ok.output_path = framed_path;
  framed_ok.format = "iso-gainmap-jpeg";
  framed_ok.parameters_json = "{\"quality\":88}";
  framed_ok.sdr = &framed_base_plane;
  framed_ok.gain = &framed;
  framed_ok.presentation_frame = 1;
  framed_ok.has_frame_photo = 1;
  framed_ok.frame_photo.x = PHOTO_X;
  framed_ok.frame_photo.y = PHOTO_Y;
  framed_ok.frame_photo.width = PHOTO_W;
  framed_ok.frame_photo.height = PHOTO_H;
  REQUIRE(hyperdr_package(engine, &framed_ok, &report, &error) == 0 && report != NULL);
  REQUIRE(contains(report, "\"gamma\":1"));
  REQUIRE(contains(report, "\"gainMin\":-0.4"));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, framed_path, "dual-rendition") == 0);

  /* The same request with a photograph rectangle that leaves part of the
   * photograph in the mat: the readback catches the gain and the half-written
   * file does not stay behind. */
  hyperdr_package_request frame_write = framed_ok;
  frame_write.output_path = framed_bad_path;
  frame_write.frame_photo.x = PHOTO_X + 8;
  frame_write.frame_photo.width = PHOTO_W - 16;
  frame_write.frame_photo.y = PHOTO_Y + 4;
  frame_write.frame_photo.height = PHOTO_H - 8;
  REQUIRE(hyperdr_package(engine, &frame_write, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(contains(error->message, "carries gain"));
  hyperdr_error_free(error);
  error = NULL;
  REQUIRE(access(framed_bad_path, F_OK) != 0);

  /* A rectangle without the frame intention, or one outside the canvas, is a
   * caller mistake rather than a format the writer refuses. */
  hyperdr_package_request frame_mistake = frame_write;
  frame_mistake.output_path = framed_bad_path;
  frame_mistake.presentation_frame = 0;
  REQUIRE(hyperdr_package(engine, &frame_mistake, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "invalid_options") == 0);
  hyperdr_error_free(error);
  error = NULL;
  frame_mistake = frame_write;
  frame_mistake.output_path = framed_bad_path;
  frame_mistake.frame_photo.x = WIDTH - 4;
  REQUIRE(hyperdr_package(engine, &frame_mistake, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "invalid_options") == 0);
  REQUIRE(contains(error->message, "inside the canvas"));
  hyperdr_error_free(error);
  error = NULL;

  /* A framed pair with differing offsets cannot reproduce its mat from the zero
   * code, so it is refused by the format rule instead of painted. */
  hyperdr_package_gain unequal = mono_gain();
  unequal.alternate_offset[0] = 1.0f / 64.0f;
  hyperdr_package_request unequal_offset = frame_write;
  unequal_offset.output_path = framed_bad_path;
  unequal_offset.gain = &unequal;
  REQUIRE(hyperdr_package(engine, &unequal_offset, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(strcmp(error->code, "unsupported_format") == 0);
  REQUIRE(contains(error->message, "same base and alternate offsets"));
  hyperdr_error_free(error);
  error = NULL;
  REQUIRE(access(framed_bad_path, F_OK) != 0);

  /* A failed mat check must leave the file the caller already had at that path
   * alone: the check runs on a staged copy, before anything is published. */
  size_t original_size = 0;
  unsigned char* original = read_all(framed_path, &original_size);
  REQUIRE(original != NULL);
  hyperdr_package_request overwrite_wrong = framed_ok;
  overwrite_wrong.parameters_json = "{\"quality\":88,\"overwrite\":true}";
  overwrite_wrong.frame_photo.x = PHOTO_X + 8;
  overwrite_wrong.frame_photo.width = PHOTO_W - 16;
  overwrite_wrong.frame_photo.y = PHOTO_Y + 4;
  overwrite_wrong.frame_photo.height = PHOTO_H - 8;
  REQUIRE(hyperdr_package(engine, &overwrite_wrong, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(contains(error->message, "carries gain"));
  hyperdr_error_free(error);
  error = NULL;
  size_t kept_size = 0;
  unsigned char* kept = read_all(framed_path, &kept_size);
  REQUIRE(kept != NULL && kept_size == original_size && memcmp(kept, original, kept_size) == 0);
  free(kept);

  /* The staging file itself is the thing that gets checked, so a refusal at the
   * publish step likewise leaves the destination alone and takes the copy with
   * it. */
  REQUIRE(hyperdr_package(engine, &framed_ok, &report, &error) != 0);
  REQUIRE(report == NULL && error != NULL);
  REQUIRE(contains(error->message, "output exists"));
  hyperdr_error_free(error);
  error = NULL;
  kept_size = 0;
  kept = read_all(framed_path, &kept_size);
  REQUIRE(kept != NULL && kept_size == original_size && memcmp(kept, original, kept_size) == 0);
  free(kept);
  free(original);
  REQUIRE(count_prefix(directory, "framed.jpg.reading") == 0);

  /* Offsets that match but are negative still mean zero gain on the mat: the
   * reconstruction is the base itself, so the readback must not invent a gain
   * out of base + offset falling below zero. */
  char framed_negative_path[512];
  snprintf(framed_negative_path, sizeof(framed_negative_path), "%s/framed-negative.jpg", directory);
  hyperdr_package_gain negative = framed;
  for (unsigned c = 0; c < 3; ++c) {
    negative.base_offset[c] = -0.5f;
    negative.alternate_offset[c] = -0.5f;
  }
  hyperdr_package_request negative_write = framed_ok;
  negative_write.output_path = framed_negative_path;
  negative_write.gain = &negative;
  REQUIRE(hyperdr_package(engine, &negative_write, &report, &error) == 0 && report != NULL);
  REQUIRE(contains(report, "\"gamma\":1"));
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, framed_negative_path, "dual-rendition") == 0);
  REQUIRE(count_prefix(directory, "framed-negative.jpg.reading") == 0);

  /* The staging name is a guess, so a file already holding it is somebody
   * else's: the export takes another name instead of overwriting and then
   * deleting it. */
  char framed_decoy_path[512];
  snprintf(framed_decoy_path, sizeof(framed_decoy_path), "%s/framed-decoy.jpg", directory);
  enum { DECOYS = 64 };
  char decoy_paths[DECOYS][640];
  char decoy_texts[DECOYS][32];
  for (int i = 0; i < DECOYS; ++i) {
    snprintf(decoy_paths[i], sizeof(decoy_paths[i]), "%s.reading.%ld.%d", framed_decoy_path,
             (long)getpid(), i);
    snprintf(decoy_texts[i], sizeof(decoy_texts[i]), "decoy %d\n", i);
    REQUIRE(write_text(decoy_paths[i], decoy_texts[i]) == 0);
  }
  hyperdr_package_request decoy_write = framed_ok;
  decoy_write.output_path = framed_decoy_path;
  REQUIRE(hyperdr_package(engine, &decoy_write, &report, &error) == 0 && report != NULL);
  hyperdr_string_free(report);
  report = NULL;
  REQUIRE(probed_as(engine, framed_decoy_path, "dual-rendition") == 0);
  for (int i = 0; i < DECOYS; ++i) {
    if (!holds_text(decoy_paths[i], decoy_texts[i])) {
      fprintf(stderr, "staging decoy %d was disturbed: %s\n", i, decoy_paths[i]);
      return 1;
    }
  }
  for (int i = 0; i < DECOYS; ++i) remove(decoy_paths[i]);

  /* Malformed requests are option errors, not format refusals. */
  hyperdr_package_request broken = write;
  broken.format = "no-such-format";
  REQUIRE(hyperdr_package(engine, &broken, &report, &error) != 0 && report == NULL);
  REQUIRE(error != NULL && strcmp(error->code, "invalid_options") == 0);
  hyperdr_error_free(error);
  error = NULL;
  broken = write;
  broken.gain = NULL;
  REQUIRE(hyperdr_package(engine, &broken, &report, &error) != 0 && report == NULL);
  REQUIRE(error != NULL && strcmp(error->code, "unsupported_format") == 0);
  hyperdr_error_free(error);
  error = NULL;
  broken = write;
  broken.sdr = NULL;
  REQUIRE(hyperdr_package(engine, &broken, &report, &error) != 0 && report == NULL);
  REQUIRE(error != NULL && strcmp(error->code, "invalid_options") == 0);
  hyperdr_error_free(error);
  error = NULL;

  hyperdr_engine_destroy(engine);
  remove(gain_path);
  remove(rgb_path);
  remove(sdr_path);
  remove(refused_path);
  remove(framed_path);
  remove(framed_negative_path);
  remove(framed_decoy_path);
  rmdir(directory);
  printf("package_test: gain-map, three-channel, framed, SDR and refusal paths all held\n");
  return 0;
}

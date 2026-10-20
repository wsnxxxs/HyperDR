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
  value.width = WIDTH;
  value.height = HEIGHT;
  value.channels = channels;
  value.format = HYPERDR_PLANE_F32;
  return value;
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
  rmdir(directory);
  printf("package_test: gain-map, three-channel, SDR and refusal paths all held\n");
  return 0;
}

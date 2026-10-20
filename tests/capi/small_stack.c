/* Language-independent regression for engine entry points on a 512 KiB stack.
 *
 * GCD worker threads and Swift's cooperative pool are far smaller than the
 * 8 MiB main thread. Codec backends must fit worker stacks, so this test intentionally runs
 * every decoding entry point first on a small pthread, before the main thread
 * can initialize lazy static tables. */

#include "hyperdr/hyperdr.h"

#include <dirent.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define SMALL_STACK_BYTES (512U * 1024U)

#define CHECK(condition) do {                                                \
  if (!(condition)) {                                                        \
    fprintf(stderr, "small_stack: failed at %s:%d: %s\n", __FILE__,         \
            __LINE__, #condition);                                           \
    return 1;                                                                \
  }                                                                          \
} while (0)

#define CHECK_OP(condition, operation) do {                                  \
  if (!(condition)) {                                                        \
    fprintf(stderr, "small_stack: %s failed at %s:%d: %s\n", operation,     \
            __FILE__, __LINE__, #condition);                                 \
    return 1;                                                                \
  }                                                                          \
} while (0)

enum Operation {
  OP_CAPABILITIES,
  OP_FRAME_LAYOUT,
  OP_PROBE_ARW,
  OP_PROBE_HEIC,
  OP_RAW_METADATA,
  OP_PREVIEW_ARW,
  OP_PREVIEW_HEIC,
  OP_MODEL_GAIN,
  OP_CONVERT,
  OP_CONVERT_JPEG,
  OP_CONVERT_ADAPTIVE,
  OP_PROBE_ISO, OP_PREVIEW_ISO, OP_CONVERT_ISO,
  OP_PROBE_XMP, OP_PREVIEW_XMP, OP_CONVERT_XMP,
  OP_PACKAGE,
  OP_COUNT
};

static const char* const kOperationNames[OP_COUNT] = {
    "capabilities", "frame_layout", "probe(ARW)", "probe(HEIC)", "raw_metadata(ARW)", "preview(ARW)",
    "preview(HEIC)", "model_gain(ARW)", "convert(HEIC, AVIF PQ)", "convert+inspect(ISO JPEG)",
    "convert(HEIC, Adaptive HEIC + write-time verification)",
    "probe(ISO JPEG)","preview(ISO JPEG)","convert(ISO JPEG)",
    "probe(XMP JPEG)","preview(XMP JPEG)","convert(XMP JPEG)",
    "package(framed gain-map JPEG from synthetic planes)"};

typedef struct {
  int status;
  unsigned char* data;
  size_t size;
} Result;

static void result_free(Result* result) {
  free(result->data);
  result->data = NULL;
  result->size = 0;
  result->status = 0;
}

static int result_append(Result* result, const void* data, size_t size) {
  if (size == 0) return 0;
  unsigned char* grown = (unsigned char*)realloc(result->data, result->size + size);
  if (!grown) return -1;
  memcpy(grown + result->size, data, size);
  result->data = grown;
  result->size += size;
  return 0;
}

static void report_error(const char* operation, const hyperdr_error* error) {
  fprintf(stderr, "small_stack: %s: %s: %s\n", operation,
          error && error->code ? error->code : "unknown",
          error && error->message ? error->message : "no message");
}

static int take_string(Result* result, const char* operation, int status,
                       char* value, hyperdr_error* error) {
  if (status != 0 || !value) {
    report_error(operation, error);
    hyperdr_string_free(value);
    hyperdr_error_free(error);
    return 1;
  }
  result->status = status;
  const int failure = result_append(result, value, strlen(value));
  hyperdr_string_free(value);
  hyperdr_error_free(error);
  return failure;
}

static int take_buffer(Result* result, const char* operation, int status,
                       hyperdr_buffer* buffer, hyperdr_error* error) {
  if (status != 0 || !buffer->data) {
    report_error(operation, error);
    hyperdr_buffer_free(buffer);
    hyperdr_error_free(error);
    return 1;
  }
  result->status = status;
  const int failure = result_append(result, buffer->data, buffer->size);
  hyperdr_buffer_free(buffer);
  hyperdr_error_free(error);
  return failure;
}

static int run_probe(hyperdr_engine* engine, const char* path, Result* result) {
  char* output = NULL;
  hyperdr_error* error = NULL;
  const int status = hyperdr_probe(engine, path, &output, &error);
  return take_string(result, "probe", status, output, error);
}

static int run_raw_metadata(hyperdr_engine* engine, const char* path, Result* result) {
  char* output = NULL;
  hyperdr_error* error = NULL;
  const int status = hyperdr_raw_metadata(engine, path, &output, &error);
  return take_string(result, "raw_metadata", status, output, error);
}

static int append_plane(Result* result, const hyperdr_plane* plane, const char* operation) {
  const size_t page = (size_t)sysconf(_SC_PAGESIZE);
  CHECK_OP(plane->format == HYPERDR_PLANE_F32, operation);
  CHECK_OP(plane->data != NULL, operation);
  CHECK_OP(plane->width > 0 && plane->height > 0, operation);
  CHECK_OP(plane->row_bytes >= (size_t)plane->width * plane->channels * sizeof(float),
           operation);
  CHECK_OP(plane->size >= plane->row_bytes * plane->height, operation);
  CHECK_OP((uintptr_t)plane->data % page == 0, operation);
  CHECK_OP(plane->size % page == 0, operation);
  const size_t used = plane->row_bytes * plane->height;
  CHECK_OP(result_append(result, plane->data, used) == 0, operation);
  return 0;
}

static int run_preview(hyperdr_engine* engine, const char* path, int packet,
                       Result* result) {
  hyperdr_preview_session* session = NULL;
  hyperdr_error* error = NULL;
  if (hyperdr_preview_open(engine, path, NULL, &session, &error) != 0 || !session) {
    report_error("preview_open", error);
    hyperdr_error_free(error);
    return 1;
  }
  const char* request = "{\"preview_max_edge\":64,\"command\":{\"compact\":true}}";
  int status = 0;
  if (packet) {
    hyperdr_buffer buffer = {0};
    status = hyperdr_preview_render(session, request, NULL, &buffer, &error);
    const int failure = take_buffer(result, "preview_render", status, &buffer, error);
    hyperdr_preview_close(session);
    return failure;
  }
  hyperdr_frame frame = {0};
  status = hyperdr_preview_render_frame(session, request, NULL, &frame, &error);
  if (status != 0 || !frame.metadata_json) {
    report_error("preview_render_frame", error);
    hyperdr_frame_free(&frame);
    hyperdr_error_free(error);
    hyperdr_preview_close(session);
    return 1;
  }
  result->status = status;
  int failure = result_append(result, frame.metadata_json, strlen(frame.metadata_json));
  if (!failure) failure = append_plane(result, &frame.base, "preview base");
  if (!failure) failure = append_plane(result, &frame.gain, "preview gain");
  hyperdr_frame_free(&frame);
  hyperdr_error_free(error);
  hyperdr_preview_close(session);
  return failure;
}

static int run_model_gain(hyperdr_engine* engine, const char* path, Result* result) {
  hyperdr_preview_session* session = NULL;
  hyperdr_error* error = NULL;
  if (hyperdr_preview_open(engine, path, NULL, &session, &error) != 0 || !session) {
    report_error("model_gain preview_open", error);
    hyperdr_error_free(error);
    return 1;
  }
  hyperdr_buffer buffer = {0};
  const char* request = "{\"command\":{\"model_id\":\"research-cnn-v1\"}}";
  const int status = hyperdr_model_gain(session, request, NULL, &buffer, &error);
  const int failure = take_buffer(result, "model_gain", status, &buffer, error);
  hyperdr_preview_close(session);
  return failure;
}

static int read_file(const char* path, Result* result) {
  FILE* file = fopen(path, "rb");
  if (!file) return 1;
  unsigned char chunk[65536];
  for (;;) {
    const size_t count = fread(chunk, 1, sizeof(chunk), file);
    if (count && result_append(result, chunk, count) != 0) {
      fclose(file);
      return 1;
    }
    if (count < sizeof(chunk)) break;
  }
  const int ok = ferror(file) == 0;
  fclose(file);
  return ok ? 0 : 1;
}

static int exported_file(const char* directory, char* path, size_t capacity) {
  DIR* dir = opendir(directory);
  if (!dir) return 1;
  int found = 0;
  struct dirent* entry = NULL;
  while ((entry = readdir(dir)) != NULL) {
    if (entry->d_name[0] == '.') continue;
    const int length = snprintf(path, capacity, "%s/%s", directory, entry->d_name);
    if (length <= 0 || (size_t)length >= capacity) {
      found = 0;
      break;
    }
    found = 1;
    break;
  }
  closedir(dir);
  return found ? 0 : 1;
}

extern int e4_inspect_jpeg(const char* path, char** output);

/* The packaging entry point takes planes rather than a photograph, so the only
 * input it needs is synthetic: a small gradient base and a one-channel gain
 * plane. Its output bytes are compared between the small and main threads like
 * every other operation here. */
#define PACKAGE_WIDTH 32
#define PACKAGE_HEIGHT 24
static float package_base[PACKAGE_WIDTH * PACKAGE_HEIGHT * 3];
static float package_gain[PACKAGE_WIDTH * PACKAGE_HEIGHT];

static int package_rows(void* user,uint32_t y,uint32_t count,float* base,float* gain) {
  (void)user;
  memcpy(base,package_base+(size_t)y*PACKAGE_WIDTH*3,(size_t)count*PACKAGE_WIDTH*3*sizeof(float));
  memcpy(gain,package_gain+(size_t)y*PACKAGE_WIDTH,(size_t)count*PACKAGE_WIDTH*sizeof(float));
  return 0;
}
static int run_package(hyperdr_engine* engine, const char* root, Result* result) {
  /* A framed canvas, so the entry point's own E5 readback (which decodes the
   * file it just wrote) also runs on this thread's small stack. */
  const int mat = 4;
  for (int y = 0; y < PACKAGE_HEIGHT; ++y) {
    for (int x = 0; x < PACKAGE_WIDTH; ++x) {
      const size_t pixel = (size_t)y * PACKAGE_WIDTH + (size_t)x;
      if (x < mat || y < mat || x >= PACKAGE_WIDTH - mat || y >= PACKAGE_HEIGHT - mat) {
        package_base[pixel * 3 + 0] = 0.18f;
        package_base[pixel * 3 + 1] = 0.18f;
        package_base[pixel * 3 + 2] = 0.18f;
        package_gain[pixel] = 0.0f;
        continue;
      }
      const float u = (float)(x - mat) / (PACKAGE_WIDTH - 1 - 2 * mat);
      const float v = (float)(y - mat) / (PACKAGE_HEIGHT - 1 - 2 * mat);
      package_base[pixel * 3 + 0] = 0.10f + 0.70f * u;
      package_base[pixel * 3 + 1] = 0.10f + 0.60f * v;
      package_base[pixel * 3 + 2] = 0.10f + 0.50f * (1.0f - u);
      package_gain[pixel] = -0.3f + 1.8f * u * v;
    }
  }
  hyperdr_package_plane base = {0}, gain = {0};
  base.data = package_base;
  base.row_bytes = (size_t)PACKAGE_WIDTH * 3 * sizeof(float);
  base.size = base.row_bytes * PACKAGE_HEIGHT;
  base.width = PACKAGE_WIDTH;
  base.height = PACKAGE_HEIGHT;
  base.channels = 3;
  base.format = HYPERDR_PLANE_F32;
  gain.data = package_gain;
  gain.row_bytes = (size_t)PACKAGE_WIDTH * sizeof(float);
  gain.size = gain.row_bytes * PACKAGE_HEIGHT;
  gain.width = PACKAGE_WIDTH;
  gain.height = PACKAGE_HEIGHT;
  gain.channels = 1;
  gain.format = HYPERDR_PLANE_F32;
  hyperdr_package_gain gain_map = {0};
  gain_map.plane = gain;
  gain_map.alternate_headroom = 1.5f;
  char path[PATH_MAX];
  const int length = snprintf(path, sizeof(path), "%s/package.jpg", root);
  if (length <= 0 || (size_t)length >= sizeof(path)) return 1;
  hyperdr_package_request request = {0};
  request.output_path = path;
  request.format = "iso-gainmap-jpeg";
  request.parameters_json = "{\"overwrite\":true}";
  request.sdr = &base;
  request.gain = &gain_map;
  request.presentation_frame = 1;
  request.has_frame_photo = 1;
  request.frame_photo.x = (uint32_t)mat;
  request.frame_photo.y = (uint32_t)mat;
  request.frame_photo.width = (uint32_t)(PACKAGE_WIDTH - 2 * mat);
  request.frame_photo.height = (uint32_t)(PACKAGE_HEIGHT - 2 * mat);
  char* report = NULL;
  hyperdr_error* error = NULL;
  const int status = hyperdr_package(engine, &request, &report, &error);
  if (status != 0 || !report) {
    report_error("package", error);
    hyperdr_string_free(report);
    hyperdr_error_free(error);
    return 1;
  }
  hyperdr_string_free(report);
  hyperdr_error_free(error);
  report = NULL; error = NULL;
  if(hyperdr_package_rows(engine,&request,13,package_rows,NULL,&report,&error)!=0) {
    report_error("package_rows",error);hyperdr_string_free(report);hyperdr_error_free(error);return 1;
  }
  hyperdr_string_free(report);hyperdr_error_free(error);
  result->status = status;
  const int failure = read_file(path, result);
  remove(path);
  return failure;
}

static int run_convert(hyperdr_engine* engine, const char* arw, const char* output,
                       const char* encoding, int jpeg,
                       Result* result) {
  char request[PATH_MAX * 2];
  const int length = snprintf(request, sizeof(request),
      "{\"encoding\":\"%s\",\"command\":{\"input\":\"%s\","
      "\"output\":\"%s\",\"overwrite\":true}}", encoding, arw, output);
  if (length <= 0 || (size_t)length >= sizeof(request)) return 1;
  char* report = NULL;
  hyperdr_error* error = NULL;
  const int status = hyperdr_convert(engine, request, NULL, NULL, NULL, &report, &error);
  if (status != 0 || !report) {
    report_error("convert", error);
    hyperdr_string_free(report);
    hyperdr_error_free(error);
    return 1;
  }
  hyperdr_string_free(report);
  hyperdr_error_free(error);
  char file[PATH_MAX];
  if (exported_file(output, file, sizeof(file)) != 0) {
    fprintf(stderr, "small_stack: convert produced no file in %s\n", output);
    return 1;
  }
  result->status = status;
  int failure = read_file(file, result);
  if (jpeg && failure == 0) {
    char* inspection = NULL;
    failure = e4_inspect_jpeg(file, &inspection);
    if (failure == 0 && inspection != NULL)
      failure = result_append(result, inspection, strlen(inspection));
    else failure = 1;
    free(inspection);
  }
  remove(file);
  return failure;
}

static int run_operation(hyperdr_engine* engine, enum Operation operation,
                         const char* arw, const char* heic, const char* root,
                         Result* result) {
  switch (operation) {
    case OP_CAPABILITIES: {
      char* output = NULL;
      hyperdr_error* error = NULL;
      const int status = hyperdr_capabilities(engine, &output, &error);
      return take_string(result, "capabilities", status, output, error);
    }
    case OP_FRAME_LAYOUT: {
      char* output = NULL;
      hyperdr_error* error = NULL;
      const int status = hyperdr_frame_layout(
          "{\"margins\":0.05,\"caption\":0.1,\"shadow\":{\"opacity\":0.1,\"blur\":0.01},"
          "\"variants\":{\"wide\":{\"minRatio\":1.25,\"reference\":\"long\",\"caption\":0.06,\"aspect\":null},"
          "\"tall\":{\"maxRatio\":0.125,\"aspect\":null}}}",
          6000, 4000, &output, &error);
      return take_string(result, "frame_layout", status, output, error);
    }
    case OP_PROBE_ARW:
      return run_probe(engine, arw, result);
    case OP_PROBE_HEIC:
      return run_probe(engine, heic, result);
    case OP_RAW_METADATA:
      return run_raw_metadata(engine, arw, result);
    case OP_PREVIEW_ARW:
      if (run_preview(engine, arw, 1, result) != 0) return 1;
      return run_preview(engine, arw, 0, result);
    case OP_PREVIEW_HEIC:
      return run_preview(engine, heic, 0, result);
    case OP_MODEL_GAIN:
      return run_model_gain(engine, arw, result);
    case OP_CONVERT:
    case OP_CONVERT_JPEG:
    case OP_CONVERT_ADAPTIVE: {
      char output[PATH_MAX];
      const int length = snprintf(output, sizeof(output), "%s/out", root);
      if (length <= 0 || (size_t)length >= sizeof(output)) return 1;
      return run_convert(engine, heic, output,
          operation == OP_CONVERT_JPEG ? "iso-gainmap-jpeg"
          : operation == OP_CONVERT_ADAPTIVE ? "adaptive" : "avif-pq",
          operation == OP_CONVERT_JPEG, result);
    }
    case OP_PROBE_ISO: case OP_PREVIEW_ISO: case OP_CONVERT_ISO:
    case OP_PROBE_XMP: case OP_PREVIEW_XMP: case OP_CONVERT_XMP: {
      const int xmp=operation>=OP_PROBE_XMP;
      const char* source=xmp ? HYPERDR_GAIN_FIXTURES "/xmp-only.jpg" : HYPERDR_GAIN_FIXTURES "/iso-rgb.jpg";
      if(operation==OP_PROBE_ISO || operation==OP_PROBE_XMP)return run_probe(engine,source,result);
      if(operation==OP_PREVIEW_ISO || operation==OP_PREVIEW_XMP)return run_preview(engine,source,0,result);
      char output[PATH_MAX];
      const int length=snprintf(output,sizeof(output),"%s/out",root);
      if(length<=0 || (size_t)length>=sizeof(output))return 1;
      return run_convert(engine,source,output,"iso-gainmap-jpeg",1,result);
    }
    case OP_PACKAGE:
      return run_package(engine, root, result);
    case OP_COUNT:
      break;
  }
  return 1;
}

static int run_suite(const char* arw, const char* heic, const char* root,
                     Result results[OP_COUNT]) {
  hyperdr_engine* engine = NULL;
  hyperdr_error* error = NULL;
  if (hyperdr_engine_create("{}", &engine, &error) != 0 || !engine) {
    report_error("engine_create", error);
    hyperdr_error_free(error);
    return 1;
  }
  int failure = 0;
  for (int operation = 0; operation < OP_COUNT && !failure; ++operation) {
    results[operation].status = 0;
    if (run_operation(engine, (enum Operation)operation, arw, heic, root,
                      &results[operation]) != 0) {
      fprintf(stderr, "small_stack: operation failed: %s\n", kOperationNames[operation]);
      failure = 1;
    }
  }
  hyperdr_engine_destroy(engine);
  return failure;
}

typedef struct {
  const char* arw;
  const char* heic;
  const char* root;
  Result* results;
  int failure;
} Worker;

static void* worker_main(void* context) {
  Worker* worker = (Worker*)context;
#if defined(__APPLE__)
  const size_t actual = pthread_get_stacksize_np(pthread_self());
  /* Darwin reports the requested stack plus its 12 KiB pthread metadata. */
  if (actual > SMALL_STACK_BYTES + 16U * 1024U) {
    fprintf(stderr, "small_stack: pthread stack is %zu bytes, expected <= %u\n",
            actual, SMALL_STACK_BYTES);
    worker->failure = 1;
    return NULL;
  }
  fprintf(stderr, "small_stack: worker pthread stack: %zu bytes\n", actual);
#endif
  worker->failure = run_suite(worker->arw, worker->heic, worker->root, worker->results);
  return NULL;
}

static int make_directory(const char* parent, const char* name, char* output,
                          size_t capacity) {
  const int length = snprintf(output, capacity, "%s/%s", parent, name);
  if (length <= 0 || (size_t)length >= capacity) return 1;
  return mkdir(output, 0700) == 0 ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s ARW HEIC\n", argv[0]);
    return 2;
  }
  const char* arw = argv[1];
  const char* heic = argv[2];
  CHECK(access(arw, R_OK) == 0);
  CHECK(access(heic, R_OK) == 0);

  char temporary[] = "/tmp/hyperdr-small-stack-XXXXXX";
  CHECK(mkdtemp(temporary) != NULL);
  char worker_root[PATH_MAX];
  char main_root[PATH_MAX];
  CHECK(make_directory(temporary, "worker", worker_root, sizeof(worker_root)) == 0);
  CHECK(make_directory(temporary, "main", main_root, sizeof(main_root)) == 0);

  Result worker_results[OP_COUNT] = {{0}};
  Worker worker = {arw, heic, worker_root, worker_results, 1};
  pthread_attr_t attributes;
  CHECK(pthread_attr_init(&attributes) == 0);
  CHECK(pthread_attr_setstacksize(&attributes, SMALL_STACK_BYTES) == 0);
  pthread_t thread;
  const int created = pthread_create(&thread, &attributes, worker_main, &worker);
  pthread_attr_destroy(&attributes);
  CHECK(created == 0);
  CHECK(pthread_join(thread, NULL) == 0);
  CHECK(worker.failure == 0);

  /* Only now, after all lazy initialization ran on the small stack, repeat on
   * the main thread with the same inputs and compare every byte. */
  Result main_results[OP_COUNT] = {{0}};
  const int main_failure = run_suite(arw, heic, main_root, main_results);
  CHECK(main_failure == 0);

  for (int operation = 0; operation < OP_COUNT; ++operation) {
    Result* small = &worker_results[operation];
    Result* large = &main_results[operation];
    if (small->status != large->status || small->size != large->size ||
        (small->size && memcmp(small->data, large->data, small->size) != 0)) {
      fprintf(stderr, "small_stack: result differs for %s: %zu vs %zu bytes\n",
              kOperationNames[operation], small->size, large->size);
      return 1;
    }
    result_free(small);
    result_free(large);
  }

  char path[PATH_MAX];
  snprintf(path, sizeof(path), "%s/out", worker_root);
  rmdir(path);
  snprintf(path, sizeof(path), "%s/out", main_root);
  rmdir(path);
  rmdir(worker_root);
  rmdir(main_root);
  rmdir(temporary);
  printf("small_stack: %d operations matched on a %u KiB thread\n", OP_COUNT,
         SMALL_STACK_BYTES / 1024);
  return 0;
}

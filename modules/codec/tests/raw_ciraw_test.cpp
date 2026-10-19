#include "../src/internal/raw_ciraw.hpp"

#include <mach/mach.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <thread>

#include "../src/internal/budget.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/model/ncnn_runtime.hpp"
using namespace hyperdr;
namespace {
void require(bool v, const char* message) {
  if (!v) throw std::runtime_error(message);
}
const auto fixtures =
    std::filesystem::path(HYPERDR_SOURCE_DIR) / "build/fixtures";
std::string model_baseline(const std::filesystem::path& path);
void run() {
  const auto source = fixtures / "sony-ilce-7s.ARW";
  const auto root = std::filesystem::path(HYPERDR_SOURCE_DIR) /
                    ("build-raw-test-" + std::to_string(getpid()));
  std::filesystem::create_directories(root);
  struct Cleanup {
    std::filesystem::path p;
    ~Cleanup() { std::filesystem::remove_all(p); }
  } cleanup{root};
  Engine engine;
  const auto before = testing::raw_filter_open_count(),
             renders = testing::raw_filter_render_count();
  auto probe = json::parse(engine.probe(source));
  require(probe.find("width")->number() == 2768 &&
              probe.find("height")->number() == 1848,
          "7S crop");
  if (const auto actual = probe.find("raw")->find("decoderVersion")->string();
      actual != "7")
    throw std::runtime_error(
        "系统给 sony-ilce-7s.ARW 的默认 decoder 从 7 变为 " + actual +
        "，按 §10 第 3 点评估后再更新记录");
  require(testing::raw_filter_render_count() == renders,
          "probe rendered pixels");
  const auto settings = json::parse(testing::raw_neutral_settings());
  for (const auto& [key, value] : settings.members()) {
    if (key == "draft")
      require(!value.boolean(), "draft enabled");
    else if (key == "gamutMapping")
      require(value.boolean(), "gamut mapping disabled");
    else
      require(value.number() == (key == "edr" ? 1 : 0),
              "neutral setting changed");
  }
  auto session = engine.preview_open(source);
  ConvertOptions options;
  options.preview_max_edge = 400;
  session->render_pixels(options);
  const auto first = testing::raw_filter_render_count();
  options.preview_max_edge = 500;
  session->render_pixels(options);
  require(testing::raw_filter_render_count() == first,
          "same RAW scale bucket rendered again");
  options.preview_max_edge = 900;
  session->render_pixels(options);
  const auto second = testing::raw_filter_render_count();
  options.preview_max_edge = 450;
  session->render_pixels(options);
  require(testing::raw_filter_render_count() == second,
          "returning to a cached RAW scale bucket rendered again");
  PreviewRegion detail;
  detail.center = true;
  detail.width = 32;
  detail.height = 48;
  session->render_pixels(options, detail);
  const auto full_renders = testing::raw_filter_render_count();
  options.preview_max_edge = 2000;
  session->render_pixels(options);
  require(testing::raw_filter_render_count() == full_renders,
          "detail source was not reused as scale-1 master");
  options.input = source;
  options.output_directory = root / "export";
  options.encoding = HdrEncoding::IsoGainMapJpeg;
  options.preview_max_edge = 0;
  int status{};
  const auto report =
      json::parse(engine.convert(options, nullptr, nullptr, &status));
  require(status == 0, "RAW export failed");
  const auto& file = report.find("files")->array()[0];
  require(report.find("schema")->number() == 13 &&
              file.find("raw_processing")->find("engine")->string() ==
                  "apple-ciraw",
          "RAW report");
  require(!file.find("raw_white_balance") && !file.find("target_width"),
          "removed report fields retained");
  require(testing::raw_filter_open_count() == before + 1,
          "probe/preview/detail/export reopened filter");
#ifdef NDEBUG
  constexpr auto model_reference = "apple-model-7s.json";
#else
  constexpr auto model_reference = "apple-model-7s-debug.json";
#endif
  const auto reference_bytes = read_binary_file(
      std::filesystem::path(HYPERDR_SOURCE_DIR) / "tests/fixtures/raw-ciraw" / model_reference);
  const auto expected = json::parse(std::string(reference_bytes.begin(), reference_bytes.end()));
  const auto actual = json::parse(model_baseline(source));
  require(actual.find("os_build")->string() == expected.find("os_build")->string(),
          "RAW model baseline OS build changed; evaluate before updating reference");
  require(actual.find("decoder")->string() == expected.find("decoder")->string(),
          "RAW model baseline decoder changed");
  const auto& models = actual.find("models")->array();
  const auto& reference = expected.find("models")->array();
  require(models.size() == reference.size(), "RAW model baseline count changed");
  for (std::size_t i = 0; i < models.size(); ++i) {
    for (auto key : {"id", "effective", "sha256"})
      require(models[i].find(key)->string() == reference[i].find(key)->string(),
              "RAW model output changed after retiring LibRaw");
    for (auto key : {"width", "height"})
      require(models[i].find(key)->number() == reference[i].find(key)->number(),
              "RAW model output geometry changed");
  }
  auto full = decode_image(source);
  require(full.linear_p3.width == 2768 && full.linear_p3.height == 1848,
          "probe/full mismatch");
  RawDecodeOptions gain;
  gain.digital_gain = 2;
  auto doubled = decode_image(source, gain);
  for (size_t i = 0; i < full.linear_p3.pixels.size(); ++i)
    require(full.linear_p3.pixels[i] * 2 == doubled.linear_p3.pixels[i],
            "RAW gain not applied after decode");
  for (auto name : {"canon-eos-5d-iii-lossy.dng", "leica-c-portrait.RWL"}) {
    const auto header = probe_apple_raw(fixtures / name);
    const std::string expected =
        std::string(name).ends_with("dng") ? "8.dng" : "7";
    if (header.processing.decoder_version != expected)
      throw std::runtime_error(std::string("系统给 ") + name +
                               " 的默认 decoder 从 " + expected + " 变为 " +
                               header.processing.decoder_version +
                               "，按 §10 第 3 点评估后再更新记录");
    auto pixels = decode_image(fixtures / name);
    require(pixels.linear_p3.width == header.width &&
                pixels.linear_p3.height == header.height,
            "RAW full/probe mismatch");
    if (std::string(name).ends_with("RWL"))
      require(header.width == 2672 && header.height == 4000 &&
                  pixels.metadata.orientation == 1,
              "portrait rotated twice");
  }
  require(testing::raw_filter_open_count() == before + 3,
          "source replacement did not reopen filter");
  options.input = source;
  options.preview_max_edge = 500;
  options.raw.preview_max_edge = 500;
  const auto key = decode_cache_variant(options, options.raw);
  const auto system_build = raw_os_build();
  require(probe.find("raw")->find("osBuild")->string() == system_build &&
              file.find("raw_processing")->find("os_build")->string() == system_build &&
              key.find(system_build) != std::string::npos,
          "OS build differs between key, probe and report");
  const auto fingerprint = model_preprocessing_fingerprint(options);
  const auto opens = testing::raw_filter_open_count();
  testing::set_raw_os_build_override("test-build");
  require(model_preprocessing_fingerprint(options) != fingerprint,
          "OS build absent from RAW model identity");
  require(decode_cache_variant(options, options.raw) != key,
          "OS build absent from key");
  testing::set_raw_os_build_override({});
  require(testing::raw_filter_open_count() == opens,
          "cache key opened RAW filter");
  options.raw.preview_max_edge = 800;
  require(decode_cache_variant(options, options.raw) != key,
          "scale/block absent from key");
  require(raw_preview_scale(1, 4000) == .125F &&
              raw_preview_scale(501, 4000) == .25F &&
              raw_preview_scale(1001, 4000) == .5F &&
              raw_preview_scale(2001, 4000) == 1,
          "RAW scale buckets");
  const auto cache = root / "raw.hdrcache";
  require(write_decode_cache(cache, full, 1ULL << 30), "RAW cache write");
  DecodedImage cached;
  require(read_decode_cache(cache, cached) && cached.decode.raw &&
              cached.decode.raw->decoder_version == "7" &&
              cached.linear_p3.pixels == full.linear_p3.pixels,
          "RAW cache metadata/pixels");
  require(codec::ciraw_pipeline_bytes(9504, 6336, 9504, 6336, 512) ==
              150ULL * 1024 * 1024 + 28ULL * 9504 * 6336 + 16ULL * 9504 * 512,
          "RAW memory formula");
  release_apple_raw_cache(fixtures / "leica-c-portrait.RWL");
  CancelToken cancel;
  testing::set_raw_open_hook([&] { cancel.request(); });
  const auto render_before = testing::raw_filter_render_count();
  bool cancelled = false;
  try {
    CancelScope scope(&cancel);
    decode_image(source);
  } catch (const Cancelled&) {
    cancelled = true;
  }
  testing::set_raw_open_hook({});
  require(cancelled && testing::raw_filter_render_count() == render_before,
          "opening cancellation rendered first block");
  const auto unreadable = root / "unreadable.ARW";
  write_text_file_atomic(unreadable, "not raw", true);
  chmod(unreadable.c_str(), 0000);
  bool unread = false;
  try {
    probe_apple_raw(unreadable);
  } catch (const SourceUnreadable&) {
    unread = true;
  }
  chmod(unreadable.c_str(), 0600);
  require(unread, "unreadable source misclassified");
  {
    ExecutionScope execution({0, 1024 * 1024});
    bool rejected = false;
    try {
      decode_image(source);
    } catch (const RawMemoryError&) {
      rejected = true;
    }
    require(rejected, "RAW admission ignored configured budget");
  }

  // Canonical path aliases share an identity; an edited file and a changed
  // session digest must each replace the cached filter.
  const auto clone = root / "identity.ARW";
  std::filesystem::copy_file(source, clone);
  auto count = testing::raw_filter_open_count();
  probe_apple_raw(clone);
  require(testing::raw_filter_open_count() == count + 1,
          "new identity reused filter");
  const auto alias = root / "alias.ARW";
  std::filesystem::create_symlink(clone, alias);
  probe_apple_raw(alias);
  require(testing::raw_filter_open_count() == count + 1,
          "canonical alias reopened filter");
  {
    std::ofstream stream(clone, std::ios::binary | std::ios::app);
    stream.put(0);
  }
  probe_apple_raw(clone);
  require(testing::raw_filter_open_count() == count + 2,
          "changed file reused filter");
  RawDecodeOptions identity;
  identity.preview_max_edge = 64;
  identity.source_sha256 = "digest-one";
  decode_image(clone, identity);
  count = testing::raw_filter_open_count();
  identity.source_sha256 = "digest-two";
  decode_image(clone, identity);
  require(testing::raw_filter_open_count() == count + 1,
          "changed session digest reused filter");
  release_apple_raw_cache(clone);
  count = testing::raw_filter_open_count();
  probe_apple_raw(clone);
  require(testing::raw_filter_open_count() == count + 1,
          "closing photo retained filter");
  // A supplied digest must not hide replacement at the same path, even when
  // size and mtime are unchanged. Exercise both the exact source-cache hit
  // and reuse of the scale-bucket master at another requested edge.
  const auto replacement = fixtures / "leica-c-portrait.RWL";
  const auto padded_size = std::max(std::filesystem::file_size(source),
                                    std::filesystem::file_size(replacement));
  const auto master_clone = root / "master-identity.ARW";
  const auto replace = [&](const std::filesystem::path& from) {
    std::filesystem::copy_file(from, master_clone,
                              std::filesystem::copy_options::overwrite_existing);
    std::filesystem::resize_file(master_clone, padded_size);
  };
  for (unsigned edge : {64U, 80U}) {
    replace(source);
    const auto timestamp = std::filesystem::last_write_time(master_clone);
    auto cached_session = engine.preview_open(master_clone, sha256_file_hex(master_clone));
    ConvertOptions preview;
    preview.preview_max_edge = 64;
    auto original = cached_session->render_pixels(preview);
    const auto unchanged = testing::raw_filter_open_count();
    require(cached_session->render_pixels(preview).base.pixels == original.base.pixels &&
                testing::raw_filter_open_count() == unchanged,
            "unchanged source did not reuse cache");
    replace(replacement);
    std::filesystem::last_write_time(master_clone, timestamp);
    preview.preview_max_edge = edge;
    auto changed = cached_session->render_pixels(preview);
    require(testing::raw_filter_open_count() == unchanged + 1,
            "source/master cache hid file replacement with supplied digest");
    auto fresh = engine.preview_open(master_clone)->render_pixels(preview);
    require(changed.base.pixels == fresh.base.pixels &&
                changed.metadata == fresh.metadata &&
                changed.base.pixels != original.base.pixels,
            "replacement pixels or geometry differ from fresh session");
  }
  // A valid persisted model binding is accepted for its OS build, including a
  // batch whose options.input is a directory, then rejected after an OS update
  // even if CIRAWFilter keeps the same decoder version.
  ConvertOptions bound_options;
  bound_options.input = source;
  ExternalGainMap external;
  external.binding.emplace();
  auto& binding = *external.binding;
  const auto& decoded = full.decode;
  binding.source_sha256 = sha256_file_hex(source);
  binding.preprocessing_fingerprint = model_preprocessing_fingerprint(bound_options);
  binding.orientation = full.metadata.orientation;
  binding.sensor_width = decoded.sensor_width;
  binding.sensor_height = decoded.sensor_height;
  binding.requested_crop_width = decoded.target_width;
  binding.requested_crop_height = decoded.target_height;
  binding.requested_crop_left = decoded.requested_crop_left;
  binding.requested_crop_top = decoded.requested_crop_top;
  binding.delivered_crop_width = decoded.decoded_width;
  binding.delivered_crop_height = decoded.decoded_height;
  binding.delivered_crop_left = decoded.delivered_crop_left;
  binding.delivered_crop_top = decoded.delivered_crop_top;
  binding.raw_decoder_version = decoded.raw->decoder_version;
  binding.raw_scale = decoded.raw->scale;
  const auto& look = bound_options.gain.look;
  binding.recipe.contrast = look.contrast;
  binding.recipe.vibrance = look.vibrance;
  binding.recipe.pop = look.pop;
  binding.recipe.toe_end = look.toe_end;
  binding.recipe.toe_output_ratio = look.toe_output_ratio;
  binding.recipe.shoulder_start = look.shoulder_start;
  binding.recipe.positive_exposure_limit_ev = look.positive_exposure_limit_ev;
  binding.recipe.diffuse_gain_floor = look.diffuse_gain_floor;
  binding.recipe.headroom_stops = bound_options.gain.headroom_stops;
  static_cast<void>(replay_external_development(external, source, full, bound_options));
  bound_options.input = fixtures;
  static_cast<void>(replay_external_development(external, source, full, bound_options));
  testing::set_raw_os_build_override("updated-system-build");
  bool stale_binding = false;
  try {
    static_cast<void>(replay_external_development(external, source, full, bound_options));
  } catch (const std::invalid_argument& e) {
    stale_binding = std::string(e.what()).find("preprocessing changed") != std::string::npos;
  }
  testing::set_raw_os_build_override({});
  require(stale_binding, "persisted RAW binding survived OS build change");
  // A second caller can cancel while another render owns the filter lock.
  std::atomic<bool> held = false, release = false;
  testing::set_raw_block_hook([&](unsigned top, unsigned) {
    if (!top) {
      held = true;
      const auto until =
          std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
      while (!release && std::chrono::steady_clock::now() < until)
        std::this_thread::yield();
    }
  });
  std::exception_ptr first_error;
  std::thread first_worker([&] {
    try {
      decode_image(clone, identity);
    } catch (...) {
      first_error = std::current_exception();
    }
  });
  while (!held) std::this_thread::yield();
  CancelToken waiting;
  bool waiting_cancelled = false;
  std::thread second_worker([&] {
    try {
      CancelScope scope(&waiting);
      decode_image(clone, identity);
    } catch (const Cancelled&) {
      waiting_cancelled = true;
    }
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(5));
  const auto requested = std::chrono::steady_clock::now();
  waiting.request();
  second_worker.join();
  const auto tail = std::chrono::duration<double, std::milli>(
                        std::chrono::steady_clock::now() - requested)
                        .count();
  release = true;
  first_worker.join();
  testing::set_raw_block_hook({});
  if (first_error) std::rethrow_exception(first_error);
  require(waiting_cancelled && tail < 200,
          "waiting RAW caller did not cancel promptly");
}
// Frozen Apple model outputs replace the retired live LibRaw comparator.
std::string model_baseline(const std::filesystem::path& path) {
  Engine engine;
  RawDecodeOptions options;
  options.preview_max_edge = 2048;
  const auto decoded = decode_image(path, options);
  json::Writer writer;
  writer.begin_object().member("os_build", raw_os_build())
      .member("decoder", decoded.decode.raw->decoder_version).begin_array("models");
  for (auto id : {"research-cnn-v1", "research-exif-v1"}) {
    ConvertOptions conversion;
    conversion.ai_model_path = id;
    const auto inferred = infer_native_model(
        native_model_request(conversion, decoded.metadata),
        make_native_model_input(render_native_model_base(decoded, false).base_linear));
    const auto& image = inferred.signed_log2_gain;
    const auto* begin = reinterpret_cast<const std::uint8_t*>(image.pixels.data());
    const std::vector<std::uint8_t> bytes(begin, begin + image.pixels.size() * sizeof(float));
    double sum = 0;
    for (float value : image.pixels) sum += value;
    writer.begin_object().member("id", id).member("effective", inferred.effective_model_id)
        .member("width", image.width).member("height", image.height)
        .member("mean", sum / image.pixels.size())
        .member("min", *std::min_element(image.pixels.begin(), image.pixels.end()))
        .member("max", *std::max_element(image.pixels.begin(), image.pixels.end()))
        .member("sha256", sha256_hex(bytes)).end_object();
  }
  return writer.end_array().end_object().take();
}
int model_measure(const std::filesystem::path& path) {
  std::cout << model_baseline(path) << '\n';
  return 0;
}
int lens_measure(const std::filesystem::path& path) {
  auto enabled = decode_image(path);
  RawDecodeOptions options;
  options.lens_correction = false;
  auto disabled = decode_image(path, options);
  require(enabled.linear_p3.width == disabled.linear_p3.width &&
              enabled.linear_p3.height == disabled.linear_p3.height,
          "lens output geometry changed");
  double sum = 0, maximum = 0;
  std::size_t changed = 0;
  for (std::size_t i = 0; i < enabled.linear_p3.pixels.size(); ++i) {
    const double d =
        std::abs(enabled.linear_p3.pixels[i] - disabled.linear_p3.pixels[i]);
    sum += d;
    maximum = std::max(maximum, d);
    changed += d != 0;
  }
  std::cout << "lens_supported="
            << enabled.decode.raw->lens_correction_supported
            << " enabled_applied="
            << enabled.decode.raw->lens_correction_applied
            << " disabled_applied="
            << disabled.decode.raw->lens_correction_applied
            << " changed_channels=" << changed
            << " mean_abs=" << sum / enabled.linear_p3.pixels.size()
            << " max_abs=" << maximum << '\n';
  return 0;
}

int export_measure(const std::filesystem::path& path) {
  const auto root =
      std::filesystem::path(HYPERDR_SOURCE_DIR) / "build-r1/private-export";
  struct Cleanup {
    std::filesystem::path p;
    ~Cleanup() { std::filesystem::remove_all(p); }
  } cleanup{root};
  EngineConfig config;
  config.memory_budget_bytes = 8ULL * 1024 * 1024 * 1024;
  Engine engine(config);
  ConvertOptions options;
  options.input = path;
  options.output_directory = root;
  options.encoding = HdrEncoding::IsoGainMapJpeg;
  CancelToken token;
  testing::set_raw_block_hook([&](unsigned, unsigned) { token.request(); });
  bool cancelled = false;
  try {
    engine.convert(options, nullptr, &token);
  } catch (const Cancelled&) {
    cancelled = true;
  }
  testing::set_raw_block_hook({});
  require(cancelled, "RAW export swallowed cancellation");
  if (std::filesystem::exists(root))
    for (const auto& entry : std::filesystem::directory_iterator(root))
      require(!entry.is_regular_file(),
              "cancelled RAW export left an output file");
  int status{};
  const auto started = std::chrono::steady_clock::now();
  const auto report =
      json::parse(engine.convert(options, nullptr, nullptr, &status));
  const auto& file = report.find("files")->array()[0];
  require(status == 0 && file.find("success")->boolean(), "61MP export failed");
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  task_info(mach_task_self(), TASK_VM_INFO,
            reinterpret_cast<task_info_t>(&info), &count);
  std::cout << "RAW export cancelled_without_output=1 width="
            << file.find("width")->number()
            << " height=" << file.find("height")->number() << " decoder="
            << file.find("raw_processing")->find("decoder_version")->string()
            << " budget_bytes=" << config.memory_budget_bytes
            << " peak_footprint_bytes=" << info.ledger_phys_footprint_peak
            << " export_ms="
            << std::chrono::duration<double, std::milli>(
                   std::chrono::steady_clock::now() - started)
                   .count()
            << '\n';
  require(info.ledger_phys_footprint_peak <= config.memory_budget_bytes,
          "61MP export footprint exceeded configured budget");
  return 0;
}

int cancel_measure(const std::filesystem::path& path) {
  probe_apple_raw(path);  // Opening/download latency is measured separately
                          // from render cancellation.
  for (unsigned delay : {1U, 10U, 25U, 50U}) {
    CancelToken token;
    std::atomic<bool> started = false, done = false;
    bool cancelled = false;
    std::exception_ptr failure;
    testing::set_raw_block_hook([&](unsigned, unsigned) { started = true; });
    const auto start = std::chrono::steady_clock::now();
    std::thread worker([&] {
      try {
        CancelScope scope(&token);
        decode_image(path);
      } catch (const Cancelled&) {
        cancelled = true;
      } catch (...) {
        failure = std::current_exception();
      }
      done = true;
    });
    while (!started.load() && !done.load()) std::this_thread::yield();
    if (done.load()) {
      worker.join();
      testing::set_raw_block_hook({});
      if (failure) std::rethrow_exception(failure);
      throw std::runtime_error("RAW finished before first render block");
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(delay));
    const auto requested = std::chrono::steady_clock::now();
    token.request();
    worker.join();
    testing::set_raw_block_hook({});
    if (failure) std::rethrow_exception(failure);
    const double tail = std::chrono::duration<double, std::milli>(
                            std::chrono::steady_clock::now() - requested)
                            .count();
    std::cout << "RAW cancel request_after_block_start_ms=" << delay
              << " tail_ms=" << tail << " cancelled=" << cancelled << '\n';
    require(cancelled && tail <= 200,
            "61MP RAW block cancellation exceeded 200 ms");
    (void)start;
  }
  const auto start = std::chrono::steady_clock::now();
  auto image = decode_image(path);
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  task_info(mach_task_self(), TASK_VM_INFO,
            reinterpret_cast<task_info_t>(&info), &count);
  std::cout << "RAW full_width=" << image.linear_p3.width
            << " full_height=" << image.linear_p3.height << " full_ms="
            << std::chrono::duration<double, std::milli>(
                   std::chrono::steady_clock::now() - start)
                   .count()
            << " physical_footprint_bytes=" << info.phys_footprint
            << " peak_footprint_bytes=" << info.ledger_phys_footprint_peak
            << '\n';
  return 0;
}

}  // namespace
int main(int argc, char** argv) {
  if (argc == 3) try {
      if (std::string(argv[1]) == "model") return model_measure(argv[2]);
      if (std::string(argv[1]) == "lens") return lens_measure(argv[2]);
      if (std::string(argv[1]) == "export") return export_measure(argv[2]);
      if (std::string(argv[1]) == "cancel") return cancel_measure(argv[2]);
    } catch (const std::exception& e) {
      std::cerr << e.what() << '\n';
      return 1;
    }
  int result = 1;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setstacksize(&attr, 512 * 1024);
  pthread_t thread;
  if (pthread_create(
          &thread, &attr,
          [](void* p) -> void* {
            try {
              run();
              *static_cast<int*>(p) = 0;
              std::cout << "CIRAW cold 512KB, probe, versions, scale reuse, "
                           "cache, identity, settings, gain, report and "
                           "cancellation passed\n";
            } catch (const std::exception& e) {
              std::cerr << e.what() << '\n';
            }
            return nullptr;
          },
          &result))
    return 2;
  pthread_attr_destroy(&attr);
  pthread_join(thread, nullptr);
  return result;
}

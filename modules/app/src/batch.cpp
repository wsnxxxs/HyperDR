#include "hyperdr/app/batch.hpp"

#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/discovery.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/resume_state.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/image/resample.hpp"

#include <algorithm>
#include <chrono>
#include <iostream>
#include <new>
#include <set>
#include <utility>

namespace hyperdr {
namespace {

using Clock = std::chrono::steady_clock;

double milliseconds(Clock::time_point begin, Clock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - begin).count();
}

// The decode-cache variant string has to name every option that changes decoded
// pixels, and nothing else: naming too much makes every slider move a miss.
std::string decode_variant(const ConvertOptions& options,
                           const RawDecodeOptions& raw) {
  const char* intent = options.decode_intent == DecodeIntent::Preview
                           ? "preview"
                           : "export";
  return std::string(intent) + '/' +
         highlight_recovery_name(raw.highlight_recovery) + '/' +
         (raw.half_size ? "half" : "full") + '/' +
         std::to_string(options.preview_max_edge);
}

// One file's work is split in two so a batch can overlap the stages. A staged
// item whose decode failed, or which was skipped, already carries its final
// result.
struct Staged {
  FileResult result;
  DecodedImage image;
  InputStamp input_stamp{};
  bool decoded{false};
  double decode_ms{};
};

Staged decode_stage(const std::filesystem::path& path,
                    const ConvertOptions& options,
                    const std::string& fingerprint) {
  Staged staged;
  staged.result.input = path;
  try {
    staged.result.output = output_path_for(path, options);
    if (options.skip_existing &&
        output_is_current(staged.result.output, path, options, fingerprint)) {
      staged.result.success = true;
      staged.result.skipped = true;
      staged.result.message = "skipped: output matches the current settings";
      return staged;
    }
    const auto start = Clock::now();
    staged.input_stamp = input_stamp(path);
    auto raw = options.raw;

    std::filesystem::path cache_file;
    if (!options.decode_cache_directory.empty()) {
      cache_file = decode_cache_path(
          options.decode_cache_directory,
          decode_cache_key(path, decode_variant(options, raw)));
    }
    if (cache_file.empty() || !read_decode_cache(cache_file, staged.image)) {
      staged.image = decode_image(path, raw);
      staged.image.linear_p3 =
          resample_to_max_edge(std::move(staged.image.linear_p3), options.preview_max_edge);
      if (!cache_file.empty()) {
        static_cast<void>(write_decode_cache(cache_file, staged.image,
                                             options.decode_cache_budget_bytes));
      }
    }
    staged.decode_ms = milliseconds(start, Clock::now());
    staged.decoded = true;
  } catch (const std::bad_alloc&) {
    staged.decoded = false;
    staged.result.message = options.decode_intent == DecodeIntent::Export
                                ? "insufficient memory for full-resolution decode"
                                : "insufficient memory for preview decode";
  } catch (const std::exception& e) {
    staged.decoded = false;
    staged.result.message = e.what();
  }
  return staged;
}

std::vector<std::uint8_t> encode_for(const GainMapResult& images,
                                     const PhotoMetadata& metadata,
                                     const ConvertOptions& options) {
  switch (options.encoding) {
    case HdrEncoding::Adaptive:
      return encode_adaptive_heic(images, metadata, options.quality, options.depth);
    case HdrEncoding::UltraHdr:
      return encode_ultrahdr_jpeg(images, metadata, options.quality);
    case HdrEncoding::AvifPq:
    case HdrEncoding::AvifHlg:
      return encode_avif(images, metadata, options.quality, options.encoding);
    case HdrEncoding::Pq:
    case HdrEncoding::Hlg:
      break;
  }
  return encode_hdr_heic(images, metadata, options.quality, options.encoding);
}

void verify_encoded(const std::vector<std::uint8_t>& bytes,
                    const ConvertOptions& options) {
  if (options.encoding == HdrEncoding::UltraHdr) verify_ultrahdr_jpeg(bytes);
  else if (is_avif_encoding(options.encoding)) verify_avif_decodable(bytes);
  else verify_heic_decodable(bytes, options.encoding);
}

void finish_stage(Staged& staged, const ConvertOptions& options,
                  const std::string& fingerprint) {
  if (!staged.decoded) return;
  auto& result = staged.result;
  try {
    const auto decoded = Clock::now();
    require_decode_resolution(options, staged.image.decode);
    auto gain = make_gain_map(staged.image.linear_p3, options.gain, staged.image.capture);
    result.sensor_width = staged.image.decode.sensor_width;
    result.sensor_height = staged.image.decode.sensor_height;
    result.target_width = staged.image.decode.target_width;
    result.target_height = staged.image.decode.target_height;
    result.decoded_width = staged.image.decode.decoded_width;
    result.decoded_height = staged.image.decode.decoded_height;
    result.target_dimensions_applied =
        staged.image.decode.target_dimensions_applied;
    result.default_crop_present = staged.image.decode.default_crop_present;
    result.decode_degraded = staged.image.decode.degraded;
    result.decode_degradation_reasons =
        staged.image.decode.degradation_reasons;
    result.width = gain.base_linear.width;
    result.height = gain.base_linear.height;
    result.exposure_ev = gain.exposure_ev;
    result.headroom_stops = gain.headroom_stops;
    result.stats = gain.stats;
    result.gain_min = rational_value(gain.metadata.gain_min);
    result.gain_max = rational_value(gain.metadata.gain_max);
    // Release the largest no-longer-needed allocation before encoding.
    staged.image.linear_p3 = {};
    const auto processed = Clock::now();

    auto bytes = encode_for(gain, staged.image.metadata, options);
    gain = {};  // Free the float base and gain before the decoder allocates.
    if (options.verify_output) {
      verify_encoded(bytes, options);
      result.self_verified = true;
    }
    if (input_stamp(result.input) != staged.input_stamp) {
      throw std::runtime_error("input changed during conversion");
    }
    write_binary_file_atomic(result.output, bytes, options.overwrite);
    const auto encoded = Clock::now();
    result.decode_ms = staged.decode_ms;
    result.process_ms = milliseconds(decoded, processed);
    result.encode_ms = milliseconds(processed, encoded);
    result.success = true;
    result.message = "ok";
    write_resume_state(result.output, result.input, staged.input_stamp, options, fingerprint);
  } catch (const std::bad_alloc&) {
    result.success = false;
    result.message = options.decode_intent == DecodeIntent::Export
                         ? "insufficient memory for full-resolution export"
                         : "insufficient memory for preview export";
  } catch (const std::exception& e) {
    result.success = false;
    result.message = e.what();
  }
}

// Distinct inputs that would land on the same output would race, and the winner
// would be arbitrary. Detected before any work starts.
void check_output_collisions(const std::vector<std::filesystem::path>& files,
                             const ConvertOptions& options) {
  std::set<PathKey> outputs;
  for (const auto& file : files) {
    const auto output = output_path_for(file, options);
    if (!outputs.insert(path_key(output)).second) {
      throw std::runtime_error("multiple inputs map to the same output: " +
                               path_utf8(output));
    }
  }
  if (options.report_path.empty()) return;
  const auto report = path_key(options.report_path);
  if (outputs.contains(report)) {
    throw std::runtime_error("report path collides with an image output");
  }
  for (const auto& file : files) {
    if (path_key(file) == report) {
      throw std::runtime_error("report path collides with an input image");
    }
  }
}

}  // namespace

void require_decode_resolution(const ConvertOptions& options,
                               const DecodeInfo& decode) {
  if (options.decode_intent == DecodeIntent::Export &&
      decode.resolution_reduced) {
    throw std::runtime_error(
        "full-resolution export produced a reduced-resolution decode");
  }
}

FileResult convert_file(const std::filesystem::path& input,
                        const ConvertOptions& options,
                        const std::string& fingerprint) {
  auto staged = decode_stage(input, options, fingerprint);
  finish_stage(staged, options, fingerprint);
  return staged.result;
}

int run_conversion(const ConvertOptions& options) {
  validate_convert_options(options);
  const auto files = discover_input_files(options);
  check_output_collisions(files, options);

  std::filesystem::create_directories(options.output_directory);
  if (!options.decode_cache_directory.empty()) {
    std::filesystem::create_directories(options.decode_cache_directory);
    prune_decode_cache(options.decode_cache_directory, options.decode_cache_budget_bytes);
  }

  const auto fingerprint = settings_fingerprint(options);
  std::vector<FileResult> results(files.size());
  const auto announce = [&](const FileResult& result,
                            const std::filesystem::path& file) {
    std::cerr << (result.skipped ? "skip: " : (result.success ? "ok: " : "error: "))
              << path_utf8(file);
    if (!result.success) std::cerr << ": " << result.message;
    std::cerr << '\n';
    // A degraded decode still succeeds for non-resolution conditions such as
    // rejected crop metadata. Resolution is not a degradable export property:
    // RAW half-size is selected explicitly by preview callers only.
    if (result.success && result.decode_degraded) {
      std::cerr << "warning: " << path_utf8(file) << ": decoded at "
                << result.decoded_width << 'x' << result.decoded_height;
      // Only phrase this as a shortfall against the target when the target was
      // actually applied; otherwise target_* is the request that was refused
      // and comparing the two would read as a resolution loss it is not.
      if (result.target_dimensions_applied) {
        std::cerr << " instead of " << result.target_width << 'x'
                  << result.target_height;
      } else {
        std::cerr << ", ignoring the recorded " << result.target_width << 'x'
                  << result.target_height << " crop";
      }
      std::cerr << " (";
      for (std::size_t i = 0; i < result.decode_degradation_reasons.size(); ++i) {
        if (i != 0) std::cerr << ", ";
        std::cerr << result.decode_degradation_reasons[i];
      }
      std::cerr << ")\n";
    }
  };

  for (std::size_t index = 0; index < files.size(); ++index) {
    results[index] = convert_file(files[index], options, fingerprint);
    announce(results[index], files[index]);
  }
  write_run_report(options.report_path, results, options);
  return std::all_of(results.begin(), results.end(),
                     [](const FileResult& r) { return r.success; })
             ? 0
             : 1;
}

}  // namespace hyperdr

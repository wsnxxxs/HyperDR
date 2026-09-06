#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/discovery.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/resume_state.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/input_format.hpp"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void touch(const std::filesystem::path& path) {
  std::filesystem::create_directories(path.parent_path());
  std::ofstream output(path, std::ios::binary);
  output.put('\0');
  if (!output) throw std::runtime_error("cannot create discovery fixture");
}

bool contains(const std::vector<std::filesystem::path>& files,
              const std::filesystem::path& path) {
  const auto expected = std::filesystem::absolute(path).lexically_normal();
  return std::any_of(files.begin(), files.end(), [&](const auto& file) {
    return std::filesystem::absolute(file).lexically_normal() == expected;
  });
}

}  // namespace

int main() {
  const auto root = std::filesystem::temp_directory_path() /
      "hyperdr-pipeline-discovery-test";
  std::filesystem::remove_all(root);
  try {
    const auto input = root / "input";
    const auto output = input / "rendered";
    const auto raw = input / "photo.arw";
    const auto jpeg = input / "nested" / "scene.jpg";
    const auto previous = output / "photo-hyperdr.heic";
    touch(raw);
    touch(jpeg);
    touch(previous);

    hyperdr::ConvertOptions options;
    options.input = input;
    options.output_directory = output;
    options.recursive = true;
    const auto nested = hyperdr::discover_input_files(options);
    require(nested.size() == 2 && contains(nested, raw) && contains(nested, jpeg),
            "recursive discovery included its nested output directory");

    // AVIF is an input as well as an output. It was the one encoding this tool
    // could write but not read, so a folder of its own results was invisible to
    // it -- and `discover_input_files` is the list that decides.
    const auto avif = input / "nested" / "scene.avif";
    touch(avif);
    const auto with_avif = hyperdr::discover_input_files(options);
    require(contains(with_avif, avif), "discovery did not accept an AVIF input");
    require(hyperdr::is_supported_input(avif), "AVIF is not a supported input");

    // LibRaw handles more than the original ARW/DNG pair. These are discovery
    // filters only; the codec still validates their actual contents.
    for (const auto extension : {".cr2", ".cr3", ".nef", ".raf", ".orf",
                                 ".rw2", ".pef"}) {
      const auto candidate = input / ("nested/raw" + std::string(extension));
      touch(candidate);
      require(hyperdr::is_supported_input(candidate),
              "a common LibRaw extension was not accepted");
    }

    // The flat raster list every caller uses is built from the per-family ones
    // the panel reads, so the two cannot drift into disagreeing about which
    // files exist. Checking the sizes add up would not catch a duplicate.
    {
      std::vector<std::string_view> families;
      families.insert(families.end(), hyperdr::kJpegExtensions.begin(),
                      hyperdr::kJpegExtensions.end());
      families.insert(families.end(), hyperdr::kPngExtensions.begin(),
                      hyperdr::kPngExtensions.end());
      families.insert(families.end(), hyperdr::kIsobmffExtensions.begin(),
                      hyperdr::kIsobmffExtensions.end());
      std::vector<std::string_view> flat(hyperdr::kRasterInputExtensions.begin(),
                                         hyperdr::kRasterInputExtensions.end());
      std::sort(families.begin(), families.end());
      std::sort(flat.begin(), flat.end());
      require(families == flat,
              "the raster families and the flat extension list disagree");
      for (const auto extension : flat) {
        require(hyperdr::extension_format(extension) !=
                    hyperdr::InputFormat::Unknown,
                "a raster extension belongs to no family");
        require(!hyperdr::is_raw_extension(extension),
                "an extension is claimed by both the RAW and raster tables");
      }
    }

    // Signature probing is the codec-free half of the dispatch, so it is pinned
    // here rather than only in the codec tests: a wrong table would otherwise
    // only surface as a decoder complaining about a marker.
    {
      const auto probe = [](std::initializer_list<std::uint8_t> head) {
        const std::vector<std::uint8_t> bytes(head);
        return hyperdr::probe_input_signature(bytes);
      };
      require(probe({0xFF, 0xD8, 0xFF, 0xE0}) == hyperdr::InputFormat::Jpeg,
              "a JPEG signature was not recognised");
      require(probe({0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A}) ==
                  hyperdr::InputFormat::Png,
              "a PNG signature was not recognised");
      require(probe({0, 0, 0, 0x18, 'f', 't', 'y', 'p', 'h', 'e', 'i', 'c'}) ==
                  hyperdr::InputFormat::Isobmff,
              "an ISO base media signature was not recognised");
      require(probe({'n', 'o', 't', ' ', 'a', 'n', ' ', 'i', 'm', 'a', 'g', 'e'}) ==
                  hyperdr::InputFormat::Unknown,
              "prose was mistaken for an image");
      // Truncation must be a miss, never a read past the end.
      require(probe({0xFF}) == hyperdr::InputFormat::Unknown,
              "a one-byte file matched a signature");

      const std::vector<std::uint8_t> rw2{'I', 'I', 'U', 0};
      const std::vector<std::uint8_t> crw{'I', 'I', 0x1A, 0};
      const std::vector<std::uint8_t> mrw{0, 'M', 'R', 'M'};
      const std::vector<std::uint8_t> prose{'p', 'l', 'a', 'i', 'n', ' ', 't', 'x'};
      require(hyperdr::raw_signature_ok(rw2) && hyperdr::raw_signature_ok(crw) &&
                  hyperdr::raw_signature_ok(mrw),
              "a RAW container the file dialog offers was not recognised");
      require(!hyperdr::raw_signature_ok(prose),
              "prose was mistaken for a RAW container");
      // RAW is never named from bytes: most of these containers are TIFF, and
      // only the extension can say which RAW a TIFF is.
      require(hyperdr::probe_input_signature(rw2) == hyperdr::InputFormat::Unknown,
              "a RAW file was classified as a raster format");
    }

    const auto same_directory_output = input / "photo-hyperdr.heic";
    touch(same_directory_output);
    options.output_directory = input;
    const auto same = hyperdr::discover_input_files(options);
    require(!contains(same, same_directory_output) && !contains(same, previous) &&
                contains(same, raw) && contains(same, jpeg),
            "same-directory discovery included generated HyperDR output");

    const auto controlled = input / "测试-image.jpg";
    touch(controlled);
    hyperdr::ConvertOptions report_options;
    report_options.input = controlled;
    report_options.output_directory = root / "report-output";
    report_options.report_path = root / "report.json";
    report_options.verify_output = false;
    require(hyperdr::run_conversion(report_options) == 1,
            "codec-free report fixture unexpectedly converted");
    std::ifstream report_file(report_options.report_path, std::ios::binary);
    const std::string report((std::istreambuf_iterator<char>(report_file)),
                             std::istreambuf_iterator<char>());
    require(report.find("\"verify_output\": false") != std::string::npos &&
                report.find("\"self_verified\": false") != std::string::npos,
            "report did not distinguish skipped verification");
    report_file.close();

    // --skip-existing is fingerprint based, not timestamp based. A newer
    // output proves nothing about which settings produced it, and the previous
    // timestamp rule therefore skipped every file after a look change and
    // shipped the old render. These three cases pin the replacement.
    hyperdr::ConvertOptions resume_options;
    const auto resumable = input / "resume.jpg";
    touch(resumable);
    resume_options.input = resumable;
    resume_options.output_directory = root / "resume-output";
    resume_options.report_path = root / "resume-report.json";
    resume_options.skip_existing = true;
    const auto resumed_output = resume_options.output_directory / "resume-hyperdr.heic";
    touch(resumed_output);
    // An output newer than its input but with no recorded provenance is stale:
    // nothing says it came from these settings.
    std::filesystem::last_write_time(
        resumable, std::filesystem::file_time_type::clock::now() -
                        std::chrono::hours(1));
    require(hyperdr::run_conversion(resume_options) != 0,
            "an output with no sidecar must not be skipped");

    hyperdr::write_resume_state(resumed_output, resumable,
                                hyperdr::input_stamp(resumable), resume_options,
                                hyperdr::settings_fingerprint(resume_options));
    require(hyperdr::run_conversion(resume_options) == 0,
            "an output recorded for these exact settings was not skipped");
    std::ifstream resume_report_file(resume_options.report_path, std::ios::binary);
    const std::string resume_report(
        (std::istreambuf_iterator<char>(resume_report_file)),
        std::istreambuf_iterator<char>());
    require(resume_report.find("\"skipped\": true") != std::string::npos,
            "resume report did not record skipped output");
    resume_report_file.close();

    // The case the timestamp rule got wrong: same input, same output, changed
    // look. The output must be regenerated.
    auto restyled = resume_options;
    restyled.gain.look.contrast = 1.25F;
    require(hyperdr::settings_fingerprint(restyled) !=
                hyperdr::settings_fingerprint(resume_options),
            "changing the look must change the fingerprint");
    require(hyperdr::run_conversion(restyled) != 0,
            "an output rendered with different settings must not be skipped");

    // Exercise the publish half with a real, checked-in image. Once an exact
    // render becomes stale, --skip-existing must replace it without requiring
    // the unrelated --overwrite switch as well. The fixture is HEIC, so the
    // dependency-free configuration skips this block.
    if (hyperdr::kCodecsAvailable) {
      hyperdr::ConvertOptions real_resume;
      real_resume.input = std::filesystem::path(HYPERDR_SOURCE_DIR) /
                          "tests/macos_t2/fixtures/gamma-2-probe.heic";
      real_resume.output_directory = root / "real-resume-output";
      real_resume.report_path = root / "real-resume-report.json";
      real_resume.skip_existing = true;
      real_resume.verify_output = false;
      require(hyperdr::run_conversion(real_resume) == 0,
              "initial resumable render failed");
      real_resume.gain.look.contrast = 1.25F;
      require(hyperdr::run_conversion(real_resume) == 0,
              "--skip-existing could not replace a stale output");
    }

    std::filesystem::remove_all(root);
    std::cout << "pipeline discovery tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::filesystem::remove_all(root);
    std::cerr << "pipeline discovery test failure: " << error.what() << '\n';
    return 1;
  }
}

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/discovery.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/resume_state.hpp"

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

    std::filesystem::remove_all(root);
    std::cout << "pipeline discovery tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::filesystem::remove_all(root);
    std::cerr << "pipeline discovery test failure: " << error.what() << '\n';
    return 1;
  }
}

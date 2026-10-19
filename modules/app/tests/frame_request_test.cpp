#include "../../../tests/support/temp_directory.hpp"
// The frame reaches an export through three doors -- the C ABI request, the
// CLI and the resume fingerprint -- and each has to agree on it. These cases
// pin that agreement without decoding a photograph.

#include "hyperdr/app/cli.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/report.hpp"

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

std::string failure(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const std::exception& e) {
    return e.what();
  }
  return {};
}

hyperdr::json::Value with_frame(const hyperdr::json::Value& request, std::string_view frame) {
  auto members = request.members();
  auto command = members.at("command").members();
  command["frame"] = hyperdr::json::parse(frame);
  members["command"] = hyperdr::json::Value::from_object(std::move(command));
  return hyperdr::json::Value::from_object(std::move(members));
}

const hyperdr::json::Value& normalized() {
  static const auto request = hyperdr::json::parse(hyperdr::normalize_options(hyperdr::json::parse(
      R"({"input": "/photos/a.jpg", "output": "/exports", "report": "/exports/report.json"})")));
  return request;
}

void test_request_carries_the_frame() {
  const auto request = with_frame(normalized(),
      R"({"background": "#F4F2EC", "margins": 0.05, "caption": 0.1})");
  const auto options = hyperdr::request_options(request);
  require(options.frame.has_value(), "command.frame must reach the convert options");
  const auto layout = hyperdr::layout_frame(*options.frame, 3000, 2000);
  require(layout.width == 3200 && layout.height == 2400, "the request's frame lays out as specified");

  const auto plain = hyperdr::request_options(normalized());
  require(!plain.frame, "a request without a frame has none");
  require(!hyperdr::request_options(with_frame(normalized(), "null")).frame,
          "a null frame means no frame");

  const auto error = failure([&] {
    (void)hyperdr::request_options(with_frame(normalized(), R"({"margin": 0.05})"));
  });
  require(error.find("frame:") != std::string::npos, "an invalid frame names the frame: " + error);
}

void test_framed_request_has_no_argv() {
  const auto request = with_frame(normalized(), R"({"margins": 0.05})");
  const auto error = failure([&] { (void)hyperdr::command_line(request); });
  require(error.find("--frame") != std::string::npos,
          "command_line must refuse a frame rather than drop it: " + error);
  require(!hyperdr::command_line(normalized()).empty(), "an unframed request still has argv");
}

void test_frame_path_is_deferred_and_has_argv() {
  const auto request = with_frame(normalized(), R"("/missing/spec with spaces.json")");
  const auto options = hyperdr::request_options(request);
  require(!options.frame && options.frame_spec_path == "/missing/spec with spaces.json",
          "request parsing must defer file reads to conversion");
  const auto args = hyperdr::command_line(request);
  const auto flag = std::find(args.begin(), args.end(), "--frame");
  require(flag != args.end() && std::next(flag) != args.end() &&
          *std::next(flag) == options.frame_spec_path, "frame file must survive argv unchanged");
  require(!failure([&] { (void)hyperdr::request_options(with_frame(normalized(), R"("")")); }).empty(),
          "empty frame path must fail");
}

void test_fingerprint_covers_the_frame() {
  const auto plain = hyperdr::request_options(normalized());
  const auto framed = hyperdr::request_options(with_frame(normalized(), R"({"margins": 0.05})"));
  const auto same = hyperdr::request_options(with_frame(normalized(),
      R"({"margins": {"top": 0.05, "right": 0.05, "bottom": 0.05, "left": 0.05}})"));
  const auto other = hyperdr::request_options(with_frame(normalized(), R"({"margins": 0.06})"));
  const auto tone = hyperdr::request_options(with_frame(normalized(),
      R"({"margins": 0.05, "background": "#000000"})"));
  require(hyperdr::settings_signature(plain) != hyperdr::settings_signature(framed),
          "adding a frame must change the fingerprint");
  require(hyperdr::settings_signature(framed) == hyperdr::settings_signature(same),
          "two spellings of one frame must share a fingerprint");
  require(hyperdr::settings_signature(framed) != hyperdr::settings_signature(other) &&
              hyperdr::settings_signature(framed) != hyperdr::settings_signature(tone),
          "a different mat or colour must change the fingerprint");

  // The overlay is an external file: its contents, not only its name, count.
  const auto folder = hyperdr::test::temporary_directory() / "hyperdr-frame-request-test";
  std::filesystem::create_directories(folder);
  const auto overlay = folder / "caption.png";
  const auto with_overlay = [&] {
    return hyperdr::request_options(with_frame(normalized(),
        R"({"margins": 0.05, "overlay": ")" + overlay.generic_string() + R"("})"));
  };
  std::ofstream(overlay, std::ios::binary) << "first";
  const auto first = hyperdr::settings_signature(with_overlay());
  const auto copied = folder / "copied.png";
  std::filesystem::copy_file(overlay, copied, std::filesystem::copy_options::overwrite_existing);
  auto relocated = with_overlay();
  relocated.frame->overlay = copied;
  require(first == hyperdr::settings_signature(relocated), "equal overlay bytes at another path must share a fingerprint");
  const auto spec = folder / "frame.json";
  std::ofstream(spec) << R"({"margins":0.05,"overlay":"caption.png"})";
  auto from_file = with_overlay();
  from_file.frame = hyperdr::read_frame_spec(spec);
  require(first == hyperdr::settings_signature(from_file), "file and inline specifications share content identity");
  std::ofstream(overlay, std::ios::binary) << "second";
  const auto second = hyperdr::settings_signature(with_overlay());
  std::filesystem::remove_all(folder);
  require(first != second, "rewriting the overlay must change the fingerprint");
}

void test_cli_reads_the_frame_file_first() {
  const auto folder = hyperdr::test::temporary_directory() / "hyperdr-frame-cli-test";
  std::filesystem::create_directories(folder);
  const auto spec = folder / "frame.json";
  std::ofstream(spec) << R"({"margins": 0.05, "colour": "#FFFFFF"})";
  std::string program = "HyperDR", command = "convert", input = (folder / "missing.jpg").string(),
              output = "--output", destination = (folder / "out").string(), flag = "--frame",
              path = spec.string();
  char* argv[] = {program.data(), command.data(), input.data(), output.data(),
                  destination.data(), flag.data(), path.data()};
  const auto error = failure([&] { (void)hyperdr::run_cli(7, argv); });
  std::filesystem::remove_all(folder);
  // The spec is rejected before the missing input is ever looked for.
  require(error.find("frame: unknown member frame.colour") != std::string::npos,
          "a malformed --frame file must fail first: " + error);
}

void test_missing_overlay_fails_before_input_or_output() {
  const auto folder = hyperdr::test::temporary_directory() / "hyperdr-frame-missing-overlay-test";
  std::filesystem::remove_all(folder);
  std::filesystem::create_directories(folder);
  const auto spec = folder / "frame.json";
  const auto overlay = folder / "caption.png";
  std::ofstream(spec) << R"({"caption":0.1,"overlay":"caption.png"})";
  std::string program = "HyperDR", command = "convert", input = (folder / "missing.jpg").string(),
              output = "--output", destination = (folder / "out").string(), flag = "--frame",
              path = spec.string();
  char* argv[] = {program.data(), command.data(), input.data(), output.data(),
                  destination.data(), flag.data(), path.data()};
  const auto cli_error = failure([&] { (void)hyperdr::run_cli(7, argv); });
  require(cli_error.find("frame: overlay") != std::string::npos &&
              cli_error.find(overlay.generic_string()) != std::string::npos,
          "CLI must name the missing overlay and resolved path: " + cli_error);
  auto options = hyperdr::request_options(with_frame(normalized(),
      R"({"caption":0.1,"overlay":")" + overlay.generic_string() + R"("})"));
  options.input = folder / "missing.jpg";
  options.output_directory = folder / "out";
  hyperdr::Engine engine;
  const auto abi_error = failure([&] { (void)engine.convert(options); });
  require(abi_error == cli_error, "engine and CLI must reject the overlay identically: " + abi_error);
  require(!std::filesystem::exists(options.output_directory), "missing overlay must not create output");
  // Geometry stays a pure computation, even when a spec names a missing overlay.
  require(!hyperdr::frame_layout(hyperdr::json::parse(
      R"({"caption":0.1,"overlay":")" + overlay.generic_string() + R"("})"), 6000, 4000).empty(),
      "frame_layout must not read the overlay");
  std::filesystem::remove_all(folder);
}

void test_report_places_the_photo() {
  hyperdr::FileResult result;
  result.success = true;
  result.message = "ok";
  result.width = 3200;
  result.height = 2400;
  result.frame = hyperdr::layout_frame(
      hyperdr::parse_frame_spec(hyperdr::json::parse(R"({"margins": 0.05, "caption": 0.1})")), 3000, 2000);
  hyperdr::FileResult plain = result;
  plain.frame.reset();
  const auto document = hyperdr::json::parse(hyperdr::run_report_json({result, plain}, {}));
  const auto& files = document.find("files")->array();
  const auto* frame = files[0].find("frame");
  require(frame && frame->find("width")->number() == 3200 &&
              frame->find("photo")->find("x")->number() == 100 &&
              frame->find("photo")->find("height")->number() == 2000,
          "the report must say where the photo sits on the canvas");
  require(files[1].find("frame") == nullptr, "an unframed export has no frame record");
}

}  // namespace

int main() try {
  try {
    test_request_carries_the_frame();
    test_framed_request_has_no_argv();
    test_frame_path_is_deferred_and_has_argv();
    test_fingerprint_covers_the_frame();
    test_cli_reads_the_frame_file_first();
    test_missing_overlay_fails_before_input_or_output();
    test_report_places_the_photo();
  } catch (const std::exception& error) {
    std::cerr << "frame_request_test failed: " << error.what() << '\n';
    return 1;
  }
  std::cout << "frame_request_test passed\n";
  return 0;
} catch (const std::exception& error) {
  std::cerr << "test failure: " << error.what() << '\n';
  return 1;
} catch (...) {
  std::cerr << "unknown test failure\n";
  return 1;
}

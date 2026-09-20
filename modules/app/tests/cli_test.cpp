#include "hyperdr/app/cli.hpp"

#include <functional>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

bool throws(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const std::invalid_argument&) {
    return true;
  }
  return false;
}

std::string failure(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const std::exception& e) {
    return e.what();
  }
  return {};
}

void test_thumbnail_rejects_identical_input_and_output() {
  char program[] = "HyperDR";
  char command[] = "thumbnail";
  char input[] = "photo.jpg";
  char output[] = "--output";
  char destination[] = "./photo.jpg";
  char* argv[] = {program, command, input, output, destination};
  require(throws([&] { static_cast<void>(hyperdr::run_cli(5, argv)); }),
          "thumbnail accepted an output path equivalent to its input");
}

void test_preview_intent_is_explicit_and_order_independent() {
  char program[] = "HyperDR";
  char command[] = "convert";
  char input[] = "missing-intent-test.arw";
  char output[] = "--output";
  char destination[] = "out";
  char edge[] = "--preview-max-edge";
  char size[] = "2048";
  char fast[] = "--fast-preview";

  char* size_only[] =
      {program, command, input, output, destination, edge, size};
  const auto export_error =
      failure([&] { static_cast<void>(hyperdr::run_cli(7, size_only)); });
  require(export_error.find("fast preview") == std::string::npos,
          "a pure size bound was inferred to be preview intent");

  char* fast_first[] =
      {program, command, input, output, destination, fast, edge, size};
  char* edge_first[] =
      {program, command, input, output, destination, edge, size, fast};
  const auto first_error =
      failure([&] { static_cast<void>(hyperdr::run_cli(8, fast_first)); });
  const auto second_error =
      failure([&] { static_cast<void>(hyperdr::run_cli(8, edge_first)); });
  require(first_error == second_error &&
              first_error.find("fast preview") == std::string::npos,
          "preview intent depends on argument order");
}

void test_thumbnail_rejects_quality_outside_documented_range() {
  char program[] = "HyperDR";
  char command[] = "thumbnail";
  char input[] = "missing-quality-test.jpg";
  char output[] = "--output";
  char destination[] = "preview.jpg";
  char quality[] = "--quality";
  char low[] = "0";
  char high[] = "101";

  char* low_argv[] =
      {program, command, input, output, destination, quality, low};
  char* high_argv[] =
      {program, command, input, output, destination, quality, high};
  const auto low_error =
      failure([&] { static_cast<void>(hyperdr::run_cli(7, low_argv)); });
  const auto high_error =
      failure([&] { static_cast<void>(hyperdr::run_cli(7, high_argv)); });
  require(low_error.find("[1,100]") != std::string::npos,
          "thumbnail accepted quality zero");
  require(high_error.find("[1,100]") != std::string::npos,
          "thumbnail accepted quality above 100");
}

// `--ai-model` now takes an id from a fixed table. Both halves matter: a bare
// flag and the legacy sentinel must keep meaning the incumbent, and a name this
// build does not have must fail before any file is opened rather than rendering
// with whatever model happened to be first.
void test_ai_model_flag_accepts_ids_and_refuses_unknown_ones() {
  char program[] = "HyperDR";
  char command[] = "convert";
  char input[] = "photo.jpg";
  char output[] = "--output";
  char destination[] = "./out";
  char flag[] = "--ai-model";
  char legacy[] = "embedded";
  char known[] = "research-exif-v1";
  char unknown[] = "research-cnn-v2";

  char* bare[] = {program, command, input, output, destination, flag};
  // Without the runtime registered the command stops at the adapter, which is
  // past the id validation this test is about.
  const std::string bare_error = failure([&] {
    static_cast<void>(hyperdr::run_cli(6, bare));
  });
  require(bare_error.find("unknown AI model id") == std::string::npos,
          "a bare --ai-model was read as an unknown model id");

  char* with_legacy[] = {program, command, input, output, destination, flag, legacy};
  const std::string legacy_error = failure([&] {
    static_cast<void>(hyperdr::run_cli(7, with_legacy));
  });
  require(legacy_error.find("unknown AI model id") == std::string::npos,
          "the legacy 'embedded' sentinel is no longer accepted");

  char* with_known[] = {program, command, input, output, destination, flag, known};
  const std::string known_error = failure([&] {
    static_cast<void>(hyperdr::run_cli(7, with_known));
  });
  require(known_error.find("unknown AI model id") == std::string::npos,
          "a model id the build carries was rejected");

  char* with_unknown[] = {program, command, input, output, destination, flag, unknown};
  const std::string unknown_error = failure([&] {
    static_cast<void>(hyperdr::run_cli(7, with_unknown));
  });
  require(unknown_error.find("unknown AI model id") != std::string::npos &&
              unknown_error.find("research-cnn-v2") != std::string::npos,
          "an unknown model id was not refused by name");
}

// The capability list is what the panel reads instead of carrying its own copy,
// so the ids, the fallback and the capture requirement all have to be in it.
void test_model_list_reports_the_table() {
  char program[] = "HyperDR";
  char command[] = "model-list";
  char json[] = "--json";
  char* argv[] = {program, command, json};
  std::ostringstream captured;
  std::streambuf* previous = std::cout.rdbuf(captured.rdbuf());
  int status = 1;
  try {
    status = hyperdr::run_cli(3, argv);
  } catch (...) {
    std::cout.rdbuf(previous);
    throw;
  }
  std::cout.rdbuf(previous);
  require(status == 0, "model-list did not succeed");
  const std::string text = captured.str();
  for (const char* expected : {"\"research-cnn-v1\"",
                               "\"research-exif-v1\"", "\"fallbackModelId\":\"research-cnn-v1\"",
                               "\"requiresExif\":true", "\"defaultModelId\":\"research-cnn-v1\""}) {
    require(text.find(expected) != std::string::npos,
            std::string("model-list is missing ") + expected);
  }
}

}  // namespace

int main() {
  try {
    test_thumbnail_rejects_identical_input_and_output();
    test_preview_intent_is_explicit_and_order_independent();
    test_thumbnail_rejects_quality_outside_documented_range();
    test_ai_model_flag_accepts_ids_and_refuses_unknown_ones();
    test_model_list_reports_the_table();
    std::cout << "cli tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}

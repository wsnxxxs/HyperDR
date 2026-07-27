#include "hyperdr/app/cli.hpp"

#include <functional>
#include <iostream>
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

}  // namespace

int main() {
  try {
    test_thumbnail_rejects_identical_input_and_output();
    test_preview_intent_is_explicit_and_order_independent();
    std::cout << "cli tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}

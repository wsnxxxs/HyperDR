// The JSON emitter replaced four hand-rolled ones, so its own guarantees --
// comma placement, escaping, and refusing to produce a broken document -- are
// what the four used to get wrong individually.
#include "hyperdr/foundation/json.hpp"

#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_nested_document_round_trips() {
  hyperdr::json::Writer writer;
  const auto text = writer.begin_object()
                        .member("name", "a \"quoted\" \\ value\n")
                        .member("count", 3)
                        .member("ratio", 0.5F)
                        .member("enabled", true)
                        .member("absent", std::optional<float>{})
                        .begin_array("values")
                        .element(1.0F)
                        .element(2.5F)
                        .end_array()
                        .begin_object("nested")
                        .member("inner", "x")
                        .end_object()
                        .end_object()
                        .take();
  const auto document = hyperdr::json::parse(text);
  require(document.find("name")->string() == "a \"quoted\" \\ value\n",
          "string member did not survive escaping");
  require(document.find("count")->number() == 3, "integer member failed");
  require(document.find("ratio")->number() == 0.5, "float member failed");
  require(document.find("enabled")->boolean(), "bool member failed");
  require(document.find("absent")->is_null(), "empty optional was not null");
  require(document.find("values")->array().size() == 2, "array member failed");
  require(document.find("nested")->find("inner")->string() == "x", "nested object failed");
}

void test_empty_containers_are_valid() {
  hyperdr::json::Writer writer;
  const auto text = writer.begin_object().begin_array("items").end_array().end_object().take();
  require(text == "{\"items\":[]}", "empty array emitted unexpected text");
  require(hyperdr::json::parse(text).find("items")->array().empty(), "empty array failed");
}

void test_indented_style_parses() {
  hyperdr::json::Writer writer(hyperdr::json::Writer::Style::kIndented);
  const auto text = writer.begin_object()
                        .begin_array("files")
                        .begin_object()
                        .member("ok", true)
                        .end_object()
                        .end_array()
                        .end_object()
                        .take();
  require(text.find('\n') != std::string::npos, "indented style produced one line");
  require(hyperdr::json::parse(text).find("files")->array().size() == 1,
          "indented document did not parse");
}

void test_structural_misuse_is_rejected() {
  const auto throws = [](auto&& fn) {
    try {
      fn();
    } catch (const std::exception&) {
      return true;
    }
    return false;
  };
  require(throws([] {
            hyperdr::json::Writer writer;
            writer.begin_object().member({}, 1);
          }),
          "an object member without a key was accepted");
  require(throws([] {
            hyperdr::json::Writer writer;
            writer.begin_array().member("key", 1);
          }),
          "an array element with a key was accepted");
  require(throws([] {
            hyperdr::json::Writer writer;
            writer.begin_object().begin_array("a").end_object();
          }),
          "a mismatched container close was accepted");
  require(throws([] {
            hyperdr::json::Writer writer;
            static_cast<void>(writer.begin_object().take());
          }),
          "an unterminated document was returned");
  require(throws([] {
            hyperdr::json::Writer writer;
            writer.begin_object().member(
                "x", std::numeric_limits<float>::quiet_NaN());
          }),
          "a non-finite number was emitted");
}

}  // namespace

int main() {
  try {
    test_nested_document_round_trips();
    test_empty_containers_are_valid();
    test_indented_style_parses();
    test_structural_misuse_is_rejected();
    std::cout << "JSON writer tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}

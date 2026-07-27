// The preset loader previously used std::regex against the raw file text,
// which cannot see nesting. These cases are the ones that silently produced a
// wrong render before: a nested object whose keys collide with top-level
// setting names, and a misspelled key that was ignored instead of reported.

#include "hyperdr/foundation/json.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

bool rejects(const std::string& text) {
  try {
    static_cast<void>(hyperdr::json::parse(text));
    return false;
  } catch (const std::invalid_argument&) {
    return true;
  }
}

void check_scalars() {
  const auto document = hyperdr::json::parse(
      R"({"a":1.5,"b":"two","c":true,"d":null,"e":[1,2,3],"f":-2e3})");
  require(document.is_object(), "top level should be an object");
  require(document.find("a") != nullptr && document.find("a")->number() == 1.5,
          "number member");
  require(document.find("b") != nullptr && document.find("b")->string() == "two",
          "string member");
  require(document.find("c") != nullptr && document.find("c")->boolean(), "bool member");
  require(document.find("d") != nullptr && document.find("d")->is_null(), "null member");
  require(document.find("e") != nullptr && document.find("e")->array().size() == 3,
          "array member");
  require(document.find("f") != nullptr && document.find("f")->number() == -2000.0,
          "exponent member");
  require(document.find("missing") == nullptr, "absent member should be null pointer");
}

// The regression that motivated this parser: a run report contains
// files[].look.contrast, and a text search for "contrast" found it.
void check_nesting_is_not_flattened() {
  const auto document = hyperdr::json::parse(
      R"({"schema":4,"files":[{"look":{"contrast":9.9,"quality":11}}]})");
  require(document.find("contrast") == nullptr,
          "a nested key must not be visible at the top level");
  require(document.find("quality") == nullptr,
          "a nested key must not be visible at the top level");
  const auto* files = document.find("files");
  require(files != nullptr && files->is_array() && files->array().size() == 1,
          "files array");
  const auto* look = files->array()[0].find("look");
  require(look != nullptr, "nested look object");
  require(look->find("contrast")->number() == 9.9, "nested value should be reachable");
}

// A key inside a string value must not be mistaken for a real member.
void check_strings_are_not_scanned() {
  const auto document = hyperdr::json::parse(R"({"note":"\"quality\": 42","quality":7})");
  require(document.find("quality")->number() == 7,
          "the real member must win over text inside a string");
  require(document.find("note")->string() == "\"quality\": 42", "escaped quotes");
}

void check_escapes() {
  const auto document = hyperdr::json::parse(
      R"({"s":"a\/b\n\t\u0041\uD83D\uDE00"})");
  const auto& value = document.find("s")->string();
  require(value.starts_with("a/b\n\tA"), "simple escapes");
  require(value.size() == 6 + 4, "a surrogate pair should decode to four UTF-8 bytes");
}

void check_rejections() {
  require(rejects("{"), "unterminated object");
  require(rejects("{\"a\":1,}"), "trailing comma");
  require(rejects("{'a':1}"), "single quotes are not JSON");
  require(rejects("{\"a\":01}"), "leading zero");
  require(rejects("{\"a\":.5}"), "missing integer part");
  require(rejects("{\"a\":1}{\"b\":2}"), "trailing content");
  require(rejects("{\"a\":1,\"a\":2}"), "duplicate key");
  require(rejects("{\"a\":\"\\uD800\"}"), "unpaired surrogate");
  require(rejects("{\"a\":\"\\x\"}"), "invalid escape");
  require(rejects("[1,2"), "unterminated array");
  // A deeply nested document must fail cleanly rather than exhaust the stack.
  require(rejects(std::string(200, '[') + std::string(200, ']')), "depth limit");
}

void check_escape_helper() {
  require(hyperdr::json::escape("a\"b\\c\nd") == R"(a\"b\\c\nd)", "escape helper");
  require(hyperdr::json::escape(std::string(1, '\x01')) == "\\u0001",
          "control characters escape as \\u00xx");
}

}  // namespace

int main() {
  try {
    check_scalars();
    check_nesting_is_not_flattened();
    check_strings_are_not_scanned();
    check_escapes();
    check_rejections();
    check_escape_helper();
  } catch (const std::exception& e) {
    std::cerr << "json_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "json_test passed\n";
  return 0;
}

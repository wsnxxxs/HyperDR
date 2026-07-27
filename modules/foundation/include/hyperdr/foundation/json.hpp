#pragma once

// A small, strict, dependency-free JSON reader.
//
// The preset loader previously searched the raw text with std::regex, which
// ignores nesting entirely: a `--report` file (whose per-file objects contain
// "contrast", "quality" and friends under a nested "look") would be read as if
// those were top-level settings, and a misspelled key was silently discarded.
// This parser resolves values structurally and lets callers reject unknown
// members, so a typo becomes an error instead of a surprising render.

#include <cstdint>
#include <map>
#include <concepts>
#include <optional>
#include <type_traits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace hyperdr::json {

enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

class Value {
 public:
  Value() = default;

  [[nodiscard]] Type type() const noexcept { return type_; }
  [[nodiscard]] bool is_null() const noexcept { return type_ == Type::kNull; }
  [[nodiscard]] bool is_bool() const noexcept { return type_ == Type::kBool; }
  [[nodiscard]] bool is_number() const noexcept { return type_ == Type::kNumber; }
  [[nodiscard]] bool is_string() const noexcept { return type_ == Type::kString; }
  [[nodiscard]] bool is_array() const noexcept { return type_ == Type::kArray; }
  [[nodiscard]] bool is_object() const noexcept { return type_ == Type::kObject; }

  [[nodiscard]] bool boolean() const;
  [[nodiscard]] double number() const;
  [[nodiscard]] const std::string& string() const;
  [[nodiscard]] const std::vector<Value>& array() const;
  [[nodiscard]] const std::map<std::string, Value>& members() const;

  // Direct member lookup; nullptr when absent or when this is not an object.
  [[nodiscard]] const Value* find(std::string_view key) const;

  // Factory helpers used by the parser and by tests.
  static Value null_value();
  static Value from_bool(bool value);
  static Value from_number(double value);
  static Value from_string(std::string value);
  static Value from_array(std::vector<Value> value);
  static Value from_object(std::map<std::string, Value> value);

 private:
  Type type_{Type::kNull};
  bool bool_{false};
  double number_{0.0};
  std::string string_;
  std::vector<Value> array_;
  std::map<std::string, Value> object_;
};

// Parses one complete JSON document. Throws std::invalid_argument with a
// byte offset on malformed input. Nesting depth is bounded so a hostile or
// corrupt file cannot exhaust the stack.
[[nodiscard]] Value parse(std::string_view text);

// Escapes a UTF-8 string for embedding in generated JSON.
[[nodiscard]] std::string escape(std::string_view text);

// A minimal structural JSON emitter.
//
// Four separate hand-rolled emitters used to build JSON with ostringstream and
// literal punctuation: the run report, the tone-curve export, the HEIF
// inspection dump, and the decode-cache sidecar. Each one owned its own comma
// placement, its own escaping (two of the three escapers differed), and its own
// float formatting, so the same number appeared with different precision in
// different files. This writer owns all three concerns once. Mismatched
// begin/end calls and values emitted outside a container throw rather than
// producing a document that only fails when something tries to parse it.
class Writer {
 public:
  enum class Style { kCompact, kIndented };

  explicit Writer(Style style = Style::kCompact) : style_(style) {}

  Writer& begin_object(std::string_view key = {});
  Writer& end_object();
  Writer& begin_array(std::string_view key = {});
  Writer& end_array();

  // Object members. `key` must be non-empty.
  Writer& member(std::string_view key, std::string_view value);
  Writer& member(std::string_view key, const char* value);
  Writer& member(std::string_view key, bool value);
  Writer& member(std::string_view key, float value);
  Writer& member(std::string_view key, double value);
  // One template rather than an overload per width: std::size_t, std::uint32_t
  // and int are all integral conversions of equal rank, so a set of fixed-width
  // overloads makes every std::size_t member ambiguous.
  template <class T>
    requires std::integral<T> && (!std::same_as<T, bool>)
  Writer& member(std::string_view key, T value) {
    if constexpr (std::is_signed_v<T>) {
      return signed_member(key, static_cast<long long>(value));
    } else {
      return unsigned_member(key, static_cast<unsigned long long>(value));
    }
  }
  // Absent optionals become JSON null, never a plausible-looking default.
  Writer& member(std::string_view key, const std::optional<float>& value);
  Writer& null_member(std::string_view key);
  // Pre-rendered JSON, for handing through a document produced elsewhere.
  Writer& raw_member(std::string_view key, std::string_view json);

  // Array elements.
  Writer& element(std::string_view value);
  // Without this, a string literal element would bind to the bool overload:
  // pointer-to-bool is a standard conversion and beats string_view's
  // user-defined one.
  Writer& element(const char* value);
  Writer& element(bool value);
  Writer& element(float value);
  Writer& element(double value);
  template <class T>
    requires std::integral<T> && (!std::same_as<T, bool>)
  Writer& element(T value) {
    return member({}, value);
  }
  Writer& elements(const std::vector<float>& values);

  // Returns the finished document and resets the writer. Throws when a
  // container is still open.
  [[nodiscard]] std::string take();

 private:
  enum class Scope { kObject, kArray };

  Writer& signed_member(std::string_view key, long long value);
  Writer& unsigned_member(std::string_view key, unsigned long long value);
  void begin_value(std::string_view key);
  void push(Scope scope, char open, std::string_view key);
  void pop(Scope scope, char close);
  void newline(std::size_t depth);

  Style style_;
  std::string out_;
  std::vector<Scope> scopes_;
  std::vector<bool> populated_;
};

// Compact, round-trip-friendly number text shared by the writer and by callers
// that still format a value into a string of their own.
[[nodiscard]] std::string number_text(float value);
[[nodiscard]] std::string number_text(double value);

}  // namespace hyperdr::json

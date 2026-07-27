#include "hyperdr/foundation/json.hpp"

#include <array>
#include <cmath>
#include <cstdio>
#include <stdexcept>

namespace hyperdr::json {
namespace {

std::string format(const char* spec, double value) {
  std::array<char, 40> buffer{};
  const int written = std::snprintf(buffer.data(), buffer.size(), spec, value);
  if (written <= 0 || static_cast<std::size_t>(written) >= buffer.size()) {
    throw std::invalid_argument("number does not fit its text form");
  }
  return std::string(buffer.data(), static_cast<std::size_t>(written));
}

// JSON has no literal for these, and a report that silently said "nan" would
// fail to parse in the panel with no indication of where it came from.
void require_finite(double value) {
  if (!std::isfinite(value)) {
    throw std::invalid_argument("cannot write a non-finite JSON number");
  }
}

}  // namespace

std::string number_text(float value) {
  require_finite(value);
  return format("%.6g", static_cast<double>(value));
}

std::string number_text(double value) {
  require_finite(value);
  return format("%.10g", value);
}

void Writer::newline(std::size_t depth) {
  if (style_ != Style::kIndented) return;
  out_.push_back('\n');
  out_.append(depth * 2, ' ');
}

void Writer::begin_value(std::string_view key) {
  if (scopes_.empty()) {
    if (!out_.empty()) throw std::logic_error("JSON document already complete");
  } else {
    const bool in_object = scopes_.back() == Scope::kObject;
    if (in_object == key.empty()) {
      throw std::logic_error(in_object ? "object members require a key"
                                       : "array elements cannot have a key");
    }
    if (populated_.back()) out_.push_back(',');
    populated_.back() = true;
    newline(scopes_.size());
    if (in_object) {
      out_.push_back('"');
      out_ += escape(key);
      out_ += style_ == Style::kIndented ? "\": " : "\":";
    }
  }
}

void Writer::push(Scope scope, char open, std::string_view key) {
  begin_value(key);
  out_.push_back(open);
  scopes_.push_back(scope);
  populated_.push_back(false);
}

void Writer::pop(Scope scope, char close) {
  if (scopes_.empty() || scopes_.back() != scope) {
    throw std::logic_error("mismatched JSON container close");
  }
  const bool had_members = populated_.back();
  scopes_.pop_back();
  populated_.pop_back();
  if (had_members) newline(scopes_.size());
  out_.push_back(close);
}

Writer& Writer::begin_object(std::string_view key) {
  push(Scope::kObject, '{', key);
  return *this;
}

Writer& Writer::end_object() {
  pop(Scope::kObject, '}');
  return *this;
}

Writer& Writer::begin_array(std::string_view key) {
  push(Scope::kArray, '[', key);
  return *this;
}

Writer& Writer::end_array() {
  pop(Scope::kArray, ']');
  return *this;
}

Writer& Writer::member(std::string_view key, std::string_view value) {
  begin_value(key);
  out_.push_back('"');
  out_ += escape(value);
  out_.push_back('"');
  return *this;
}

Writer& Writer::member(std::string_view key, const char* value) {
  return member(key, std::string_view(value == nullptr ? "" : value));
}

Writer& Writer::member(std::string_view key, bool value) {
  begin_value(key);
  out_ += value ? "true" : "false";
  return *this;
}

Writer& Writer::member(std::string_view key, float value) {
  begin_value(key);
  out_ += number_text(value);
  return *this;
}

Writer& Writer::member(std::string_view key, double value) {
  begin_value(key);
  out_ += number_text(value);
  return *this;
}

Writer& Writer::signed_member(std::string_view key, long long value) {
  begin_value(key);
  out_ += std::to_string(value);
  return *this;
}

Writer& Writer::unsigned_member(std::string_view key, unsigned long long value) {
  begin_value(key);
  out_ += std::to_string(value);
  return *this;
}

Writer& Writer::member(std::string_view key, const std::optional<float>& value) {
  return value ? member(key, *value) : null_member(key);
}

Writer& Writer::null_member(std::string_view key) {
  begin_value(key);
  out_ += "null";
  return *this;
}

Writer& Writer::raw_member(std::string_view key, std::string_view json) {
  if (json.empty()) throw std::invalid_argument("raw JSON member is empty");
  begin_value(key);
  out_ += json;
  return *this;
}

Writer& Writer::element(std::string_view value) { return member({}, value); }

Writer& Writer::element(const char* value) {
  return member({}, std::string_view(value == nullptr ? "" : value));
}

Writer& Writer::element(bool value) { return member({}, value); }
Writer& Writer::element(float value) { return member({}, value); }
Writer& Writer::element(double value) { return member({}, value); }

Writer& Writer::elements(const std::vector<float>& values) {
  for (const float value : values) element(value);
  return *this;
}

std::string Writer::take() {
  if (!scopes_.empty()) throw std::logic_error("unterminated JSON container");
  if (out_.empty()) throw std::logic_error("empty JSON document");
  std::string result;
  result.swap(out_);
  populated_.clear();
  return result;
}

}  // namespace hyperdr::json

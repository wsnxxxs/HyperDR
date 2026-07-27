#include "hyperdr/foundation/json.hpp"

#include <array>
#include <cmath>
#include <cstdlib>
#include <string>

namespace hyperdr::json {
namespace {

constexpr int kMaxDepth = 64;

[[noreturn]] void fail(std::size_t offset, const std::string& what) {
  throw std::invalid_argument("JSON error at byte " + std::to_string(offset) + ": " + what);
}

void append_utf8(std::string& out, std::uint32_t code_point) {
  if (code_point <= 0x7FU) {
    out.push_back(static_cast<char>(code_point));
  } else if (code_point <= 0x7FFU) {
    out.push_back(static_cast<char>(0xC0U | (code_point >> 6)));
    out.push_back(static_cast<char>(0x80U | (code_point & 0x3FU)));
  } else if (code_point <= 0xFFFFU) {
    out.push_back(static_cast<char>(0xE0U | (code_point >> 12)));
    out.push_back(static_cast<char>(0x80U | ((code_point >> 6) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | (code_point & 0x3FU)));
  } else {
    out.push_back(static_cast<char>(0xF0U | (code_point >> 18)));
    out.push_back(static_cast<char>(0x80U | ((code_point >> 12) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | ((code_point >> 6) & 0x3FU)));
    out.push_back(static_cast<char>(0x80U | (code_point & 0x3FU)));
  }
}

class Parser {
 public:
  explicit Parser(std::string_view text) : text_(text) {}

  Value parse_document() {
    skip_whitespace();
    Value value = parse_value(0);
    skip_whitespace();
    if (position_ != text_.size()) fail(position_, "trailing content after the JSON value");
    return value;
  }

 private:
  std::string_view text_;
  std::size_t position_{0};

  [[nodiscard]] bool at_end() const { return position_ >= text_.size(); }
  [[nodiscard]] char peek() const { return text_[position_]; }

  void skip_whitespace() {
    while (!at_end()) {
      const char c = peek();
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++position_;
      else break;
    }
  }

  void expect(char c) {
    if (at_end() || peek() != c) {
      fail(position_, std::string("expected '") + c + "'");
    }
    ++position_;
  }

  bool consume_literal(std::string_view literal) {
    if (text_.compare(position_, literal.size(), literal) != 0) return false;
    position_ += literal.size();
    return true;
  }

  Value parse_value(int depth) {
    if (depth > kMaxDepth) fail(position_, "nesting is too deep");
    if (at_end()) fail(position_, "unexpected end of input");
    switch (peek()) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Value::from_string(parse_string());
      case 't':
        if (consume_literal("true")) return Value::from_bool(true);
        fail(position_, "invalid literal");
      case 'f':
        if (consume_literal("false")) return Value::from_bool(false);
        fail(position_, "invalid literal");
      case 'n':
        if (consume_literal("null")) return Value::null_value();
        fail(position_, "invalid literal");
      default: return parse_number();
    }
  }

  Value parse_object(int depth) {
    expect('{');
    std::map<std::string, Value> members;
    skip_whitespace();
    if (!at_end() && peek() == '}') {
      ++position_;
      return Value::from_object(std::move(members));
    }
    for (;;) {
      skip_whitespace();
      const auto key_offset = position_;
      std::string key = parse_string();
      if (members.contains(key)) fail(key_offset, "duplicate key \"" + key + "\"");
      skip_whitespace();
      expect(':');
      skip_whitespace();
      members.emplace(std::move(key), parse_value(depth + 1));
      skip_whitespace();
      if (at_end()) fail(position_, "unterminated object");
      if (peek() == ',') { ++position_; continue; }
      if (peek() == '}') { ++position_; break; }
      fail(position_, "expected ',' or '}'");
    }
    return Value::from_object(std::move(members));
  }

  Value parse_array(int depth) {
    expect('[');
    std::vector<Value> items;
    skip_whitespace();
    if (!at_end() && peek() == ']') {
      ++position_;
      return Value::from_array(std::move(items));
    }
    for (;;) {
      skip_whitespace();
      items.push_back(parse_value(depth + 1));
      skip_whitespace();
      if (at_end()) fail(position_, "unterminated array");
      if (peek() == ',') { ++position_; continue; }
      if (peek() == ']') { ++position_; break; }
      fail(position_, "expected ',' or ']'");
    }
    return Value::from_array(std::move(items));
  }

  [[nodiscard]] std::uint32_t parse_hex4() {
    if (position_ + 4 > text_.size()) fail(position_, "truncated \\u escape");
    std::uint32_t value = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[position_ + static_cast<std::size_t>(i)];
      value <<= 4U;
      if (c >= '0' && c <= '9') value |= static_cast<std::uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') value |= static_cast<std::uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') value |= static_cast<std::uint32_t>(c - 'A' + 10);
      else fail(position_ + static_cast<std::size_t>(i), "invalid hex digit");
    }
    position_ += 4;
    return value;
  }

  std::string parse_string() {
    expect('"');
    std::string out;
    for (;;) {
      if (at_end()) fail(position_, "unterminated string");
      const char c = text_[position_++];
      if (c == '"') break;
      if (static_cast<unsigned char>(c) < 0x20U) fail(position_ - 1, "raw control character in string");
      if (c != '\\') { out.push_back(c); continue; }
      if (at_end()) fail(position_, "unterminated escape");
      const char escape_char = text_[position_++];
      switch (escape_char) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          std::uint32_t code_point = parse_hex4();
          if (code_point >= 0xD800U && code_point <= 0xDBFFU) {
            // A high surrogate must be followed by its low surrogate.
            if (position_ + 1 < text_.size() && text_[position_] == '\\' &&
                text_[position_ + 1] == 'u') {
              position_ += 2;
              const std::uint32_t low = parse_hex4();
              if (low < 0xDC00U || low > 0xDFFFU) fail(position_, "invalid low surrogate");
              code_point = 0x10000U + ((code_point - 0xD800U) << 10U) + (low - 0xDC00U);
            } else {
              fail(position_, "unpaired high surrogate");
            }
          } else if (code_point >= 0xDC00U && code_point <= 0xDFFFU) {
            fail(position_, "unpaired low surrogate");
          }
          append_utf8(out, code_point);
          break;
        }
        default: fail(position_ - 1, "invalid escape");
      }
    }
    return out;
  }

  Value parse_number() {
    const auto start = position_;
    if (!at_end() && peek() == '-') ++position_;
    if (at_end() || peek() < '0' || peek() > '9') fail(start, "invalid number");
    if (peek() == '0') {
      ++position_;
    } else {
      while (!at_end() && peek() >= '0' && peek() <= '9') ++position_;
    }
    if (!at_end() && peek() == '.') {
      ++position_;
      if (at_end() || peek() < '0' || peek() > '9') fail(position_, "invalid fraction");
      while (!at_end() && peek() >= '0' && peek() <= '9') ++position_;
    }
    if (!at_end() && (peek() == 'e' || peek() == 'E')) {
      ++position_;
      if (!at_end() && (peek() == '+' || peek() == '-')) ++position_;
      if (at_end() || peek() < '0' || peek() > '9') fail(position_, "invalid exponent");
      while (!at_end() && peek() >= '0' && peek() <= '9') ++position_;
    }
    const std::string literal(text_.substr(start, position_ - start));
    // std::strtod is locale-sensitive for the decimal separator, but HyperDR
    // never installs a non-"C" global locale, so this stays exact.
    const double value = std::strtod(literal.c_str(), nullptr);
    if (!std::isfinite(value)) fail(start, "number is out of range");
    return Value::from_number(value);
  }
};

}  // namespace

bool Value::boolean() const {
  if (type_ != Type::kBool) throw std::invalid_argument("JSON value is not a boolean");
  return bool_;
}

double Value::number() const {
  if (type_ != Type::kNumber) throw std::invalid_argument("JSON value is not a number");
  return number_;
}

const std::string& Value::string() const {
  if (type_ != Type::kString) throw std::invalid_argument("JSON value is not a string");
  return string_;
}

const std::vector<Value>& Value::array() const {
  if (type_ != Type::kArray) throw std::invalid_argument("JSON value is not an array");
  return array_;
}

const std::map<std::string, Value>& Value::members() const {
  if (type_ != Type::kObject) throw std::invalid_argument("JSON value is not an object");
  return object_;
}

const Value* Value::find(std::string_view key) const {
  if (type_ != Type::kObject) return nullptr;
  const auto found = object_.find(std::string(key));
  return found == object_.end() ? nullptr : &found->second;
}

Value Value::null_value() { return {}; }

Value Value::from_bool(bool value) {
  Value out;
  out.type_ = Type::kBool;
  out.bool_ = value;
  return out;
}

Value Value::from_number(double value) {
  Value out;
  out.type_ = Type::kNumber;
  out.number_ = value;
  return out;
}

Value Value::from_string(std::string value) {
  Value out;
  out.type_ = Type::kString;
  out.string_ = std::move(value);
  return out;
}

Value Value::from_array(std::vector<Value> value) {
  Value out;
  out.type_ = Type::kArray;
  out.array_ = std::move(value);
  return out;
}

Value Value::from_object(std::map<std::string, Value> value) {
  Value out;
  out.type_ = Type::kObject;
  out.object_ = std::move(value);
  return out;
}

Value parse(std::string_view text) { return Parser(text).parse_document(); }

std::string escape(std::string_view text) {
  std::string out;
  out.reserve(text.size());
  constexpr std::array<char, 16> hex{'0', '1', '2', '3', '4', '5', '6', '7',
                                     '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};
  for (const unsigned char c : text) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(static_cast<char>(c));
    } else if (c == '\b') out += "\\b";
    else if (c == '\f') out += "\\f";
    else if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c == '\t') out += "\\t";
    else if (c < 0x20U) {
      out += "\\u00";
      out.push_back(hex[c >> 4U]);
      out.push_back(hex[c & 0x0FU]);
    } else {
      out.push_back(static_cast<char>(c));
    }
  }
  return out;
}

}  // namespace hyperdr::json

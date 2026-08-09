// T3 harness: run the project's own ISO 21496-1 parser over whole corpora
// under both registered writer profiles.
//
// The gate text is "Apple samples remain accepted by apple_strict; Indigo
// samples remain rejected by apple_strict and accepted by iso_generic". The
// unit test in modules/container/tests pins that on one payload from each
// corpus, which guards against drift but says nothing about how the invariant
// holds across the corpora. This tool answers the second question with the
// same parser the writer and the inspector use, so the numbers are not
// produced by a second implementation of the same reading of the standard.
//
// Input is a tab-separated file, one sample per line:
//   <sample_id>\t<corpus>\t<payload hex>
// Payload extraction is deliberately not done here: slicing the tmap item out
// of a HEIF container is container plumbing, not validation, and doing it in
// the caller keeps this tool to the one thing it is evidence about.

#include "hyperdr/container/iso_gain_map.hpp"

#include <cstdint>
#include <exception>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::vector<std::uint8_t> bytes_from_hex(const std::string& hex) {
  if (hex.size() % 2 != 0) throw std::runtime_error("odd hex payload length");
  std::vector<std::uint8_t> bytes;
  bytes.reserve(hex.size() / 2);
  for (std::size_t index = 0; index < hex.size(); index += 2) {
    bytes.push_back(static_cast<std::uint8_t>(
        std::stoul(hex.substr(index, 2), nullptr, 16)));
  }
  return bytes;
}

std::string escape(const std::string& text) {
  std::string escaped;
  for (const char character : text) {
    if (character == '"' || character == '\\') escaped.push_back('\\');
    escaped.push_back(character);
  }
  return escaped;
}

struct Outcome {
  bool accepted{false};
  std::string message;
  std::size_t channels{0};
};

Outcome evaluate(const std::vector<std::uint8_t>& payload,
                 hyperdr::GainMapWriterProfile profile) {
  Outcome outcome;
  try {
    const auto metadata = hyperdr::parse_tmap_payload(payload, profile);
    outcome.accepted = true;
    outcome.channels = hyperdr::gain_map_channel_count(metadata);
  } catch (const std::exception& error) {
    outcome.accepted = false;
    outcome.message = error.what();
  }
  return outcome;
}

void write_outcome(std::ostream& output, const char* name,
                   const Outcome& outcome) {
  output << "\"" << name << "\":{\"accepted\":"
         << (outcome.accepted ? "true" : "false");
  if (outcome.accepted) {
    output << ",\"channels\":" << outcome.channels;
  } else {
    output << ",\"rejection\":\"" << escape(outcome.message) << "\"";
  }
  output << "}";
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: hyperdr_profile_regression <samples.tsv>\n";
    return 2;
  }
  std::ifstream input(argv[1]);
  if (!input) {
    std::cerr << "cannot open " << argv[1] << "\n";
    return 2;
  }

  std::cout << "{\"samples\":[";
  std::string line;
  bool first = true;
  std::size_t line_number = 0;
  while (std::getline(input, line)) {
    ++line_number;
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty()) continue;
    std::istringstream fields(line);
    std::string sample_id;
    std::string corpus;
    std::string hex;
    if (!std::getline(fields, sample_id, '\t') ||
        !std::getline(fields, corpus, '\t') || !std::getline(fields, hex)) {
      std::cerr << "malformed line " << line_number << "\n";
      return 2;
    }

    std::vector<std::uint8_t> payload;
    try {
      payload = bytes_from_hex(hex);
    } catch (const std::exception& error) {
      std::cerr << "line " << line_number << ": " << error.what() << "\n";
      return 2;
    }

    if (!first) std::cout << ",";
    first = false;
    std::cout << "{\"sample_id\":\"" << escape(sample_id) << "\",\"corpus\":\""
              << escape(corpus) << "\",\"payload_bytes\":" << payload.size()
              << ",";
    write_outcome(std::cout, "apple_strict",
                  evaluate(payload, hyperdr::GainMapWriterProfile::apple_strict));
    std::cout << ",";
    write_outcome(std::cout, "iso_generic",
                  evaluate(payload, hyperdr::GainMapWriterProfile::iso_generic));
    std::cout << "}";
  }
  std::cout << "]}\n";
  return 0;
}

#include "hyperdr/app/resume_state.hpp"

#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/version.hpp"

#include <cstdint>

namespace hyperdr {

InputStamp input_stamp(const std::filesystem::path& path) {
  InputStamp stamp;
  stamp.size = static_cast<std::uint64_t>(std::filesystem::file_size(path));
  stamp.modified_ns = static_cast<std::int64_t>(
      std::filesystem::last_write_time(path).time_since_epoch().count());
  return stamp;
}

std::filesystem::path resume_state_path(const std::filesystem::path& output,
                                        const ConvertOptions& options) {
  auto relative = std::filesystem::relative(output, options.output_directory);
  auto path = options.output_directory / ".hyperdr" / relative;
  path += ".json";
  return path;
}

bool output_is_current(const std::filesystem::path& output,
                       const std::filesystem::path& input,
                       const ConvertOptions& options,
                       const std::string& fingerprint) {
  std::error_code ec;
  if (!std::filesystem::is_regular_file(output, ec) || ec) return false;
  try {
    const auto bytes = read_binary_file(resume_state_path(output, options));
    const auto document = json::parse(std::string_view(
        reinterpret_cast<const char*>(bytes.data()), bytes.size()));
    const auto* schema = document.find("schema");
    if (schema == nullptr || !schema->is_number() || schema->number() != 2) return false;
    const auto* stored = document.find("fingerprint");
    if (stored == nullptr || !stored->is_string() || stored->string() != fingerprint) {
      return false;
    }
    const auto stamp = input_stamp(input);
    const auto* size = document.find("input_size");
    if (size == nullptr || !size->is_number() ||
        static_cast<std::uint64_t>(size->number()) != stamp.size) {
      return false;
    }
    // Stored as a string: a filesystem clock tick count is around 1.7e18, which
    // a JSON double cannot represent exactly, so a numeric round trip would
    // quietly compare two different values and never match.
    const auto* modified = document.find("input_modified_ns");
    if (modified == nullptr || !modified->is_string() ||
        modified->string() != std::to_string(stamp.modified_ns)) {
      return false;
    }
    const auto output_size = static_cast<std::uint64_t>(std::filesystem::file_size(output));
    const auto* stored_output_size = document.find("output_size");
    if (stored_output_size == nullptr || !stored_output_size->is_number() ||
        static_cast<std::uint64_t>(stored_output_size->number()) != output_size) {
      return false;
    }
    const auto* output_hash = document.find("output_sha256");
    return output_hash != nullptr && output_hash->is_string() &&
           output_hash->string() == sha256_file_hex(output);
  } catch (const std::exception&) {
    return false;
  }
}

void write_resume_state(const std::filesystem::path& output,
                        const std::filesystem::path& input,
                        InputStamp decoded_input_stamp,
                        const ConvertOptions& options,
                        const std::string& fingerprint) {
  try {
    const auto stamp = decoded_input_stamp;
    const auto output_size = static_cast<std::uint64_t>(std::filesystem::file_size(output));
    const auto output_hash = sha256_file_hex(output);
    json::Writer writer;
    const auto text = writer.begin_object()
                          .member("schema", 2)
                          .member("fingerprint", fingerprint)
                          .member("input", path_utf8(input))
                          .member("input_size", stamp.size)
                          .member("input_modified_ns", std::to_string(stamp.modified_ns))
                          .member("output_size", output_size)
                          .member("output_sha256", output_hash)
                          .member("tool", kVersion)
                          .member("settings", settings_signature(options))
                          .end_object()
                          .take();
    write_text_file_atomic(resume_state_path(output, options), text + "\n", true);
  } catch (const std::exception&) {
    // The next run simply treats the output as stale.
  }
}

}  // namespace hyperdr

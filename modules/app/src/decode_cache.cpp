#include "hyperdr/app/decode_cache.hpp"

#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/version.hpp"

#include <algorithm>
#include <array>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

namespace hyperdr {
namespace {

constexpr std::array<char, 8> kMagic{'H', 'D', 'R', 'C', 'A', 'C', 'H', '3'};

// Bumped whenever the metadata JSON or the binary layout changes shape. The
// magic alone could not express "same container, different contents", so a
// build that started writing a new field would silently read old entries that
// lacked it -- which is how a cache hit came to produce different Exif from
// the decode that filled it.
constexpr std::uint32_t kCacheSchema = 6;

// x86-64 and arm64, the only targets this project builds for, are both little
// endian; the cache is a local scratch format and is never transported.
static_assert(sizeof(float) == 4, "cache format assumes 32-bit float");

void put_u32(std::vector<std::uint8_t>& out, std::uint32_t value) {
  out.push_back(static_cast<std::uint8_t>(value & 0xFFU));
  out.push_back(static_cast<std::uint8_t>((value >> 8U) & 0xFFU));
  out.push_back(static_cast<std::uint8_t>((value >> 16U) & 0xFFU));
  out.push_back(static_cast<std::uint8_t>((value >> 24U) & 0xFFU));
}

std::uint32_t get_u32(const std::uint8_t* data) {
  return static_cast<std::uint32_t>(data[0]) |
         (static_cast<std::uint32_t>(data[1]) << 8U) |
         (static_cast<std::uint32_t>(data[2]) << 16U) |
         (static_cast<std::uint32_t>(data[3]) << 24U);
}

std::optional<float> read_optional(const json::Value& parent, std::string_view key) {
  const auto* value = parent.find(key);
  if (value == nullptr || !value->is_number()) return std::nullopt;
  return static_cast<float>(value->number());
}

// Every field of PhotoMetadata and CaptureMetadata, without exception.
//
// The previous version serialised ten of them and dropped lens_make, artist,
// software, focal_length_35mm and GPS on the floor, so the same input produced
// different Exif and XMP depending on whether the decode had been cached --
// a difference that only appears on the second run and never in a single-run
// test. A field added to PhotoMetadata, CaptureMetadata, DecodeInfo or
// DecodedImage itself must be added here too; the schema number above exists so
// that forgetting is a miss rather than a silent loss.
std::string metadata_json(const DecodedImage& value) {
  const auto& m = value.metadata;
  const auto& c = value.capture;
  const auto& d = value.decode;
  json::Writer writer;
  writer.begin_object()
      .member("make", m.make)
      .member("model", m.model)
      .member("lens", m.lens)
      .member("lens_make", m.lens_make)
      .member("artist", m.artist)
      .member("date_time", m.date_time)
      .member("copyright", m.copyright)
      .member("software", m.software)
      .member("orientation", m.orientation)
      .member("iso", m.iso)
      .member("exposure_seconds", m.exposure_seconds)
      .member("aperture", m.aperture)
      .member("focal_length_mm", m.focal_length_mm)
      .member("focal_length_35mm", m.focal_length_35mm)
      .member("capture_iso", c.iso)
      .member("capture_exposure_time_seconds", c.exposure_time_seconds)
      .member("capture_aperture_f_number", c.aperture_f_number)
      .member("decode_sensor_width", d.sensor_width)
      .member("decode_sensor_height", d.sensor_height)
      .member("decode_target_width", d.target_width)
      .member("decode_target_height", d.target_height)
      .member("decode_requested_crop_left", d.requested_crop_left)
      .member("decode_requested_crop_top", d.requested_crop_top)
      .member("decode_delivered_crop_left", d.delivered_crop_left)
      .member("decode_delivered_crop_top", d.delivered_crop_top)
      .member("decode_decoded_width", d.decoded_width)
      .member("decode_decoded_height", d.decoded_height)
      .member("decode_resolution_reduced", d.resolution_reduced)
      .member("decode_target_dimensions_applied", d.target_dimensions_applied)
      .member("decode_default_crop_present", d.default_crop_present)
      .member("decode_degraded", d.degraded)
      // Not metadata about the photograph but about its encoding, and the
      // preview divides by it: a cache hit that lost it would serve an HDR
      // input's thumbnail unscaled and the panel would clip it.
      .member("hdr_headroom", value.hdr_headroom)
      .member("has_gps", m.gps.has_value());
  writer.begin_array("decode_degradation_reasons");
  for (const auto& reason : d.degradation_reasons) {
    writer.element(reason);
  }
  writer.end_array();
  if (m.gps) {
    writer.member("gps_latitude", m.gps->latitude_degrees)
        .member("gps_longitude", m.gps->longitude_degrees);
    if (m.gps->altitude_metres) {
      writer.member("gps_altitude", *m.gps->altitude_metres);
    }
  }
  return writer.end_object().take();
}

void apply_metadata_json(const std::string& text, DecodedImage& out) {
  const auto document = json::parse(text);
  const auto string_at = [&](std::string_view key) -> std::string {
    const auto* value = document.find(key);
    return value != nullptr && value->is_string() ? value->string() : std::string{};
  };
  const auto number_at = [&](std::string_view key) -> double {
    const auto* value = document.find(key);
    return value != nullptr && value->is_number() ? value->number() : 0.0;
  };
  const auto flag_at = [&](std::string_view key) -> bool {
    const auto* value = document.find(key);
    return value != nullptr && value->is_bool() && value->boolean();
  };
  out.metadata.make = string_at("make");
  out.metadata.model = string_at("model");
  out.metadata.lens = string_at("lens");
  out.metadata.lens_make = string_at("lens_make");
  out.metadata.artist = string_at("artist");
  out.metadata.date_time = string_at("date_time");
  out.metadata.copyright = string_at("copyright");
  out.metadata.software = string_at("software");
  out.metadata.orientation = static_cast<std::uint16_t>(number_at("orientation"));
  out.metadata.iso = static_cast<std::uint32_t>(number_at("iso"));
  out.metadata.exposure_seconds = number_at("exposure_seconds");
  out.metadata.aperture = number_at("aperture");
  out.metadata.focal_length_mm = number_at("focal_length_mm");
  out.metadata.focal_length_35mm = number_at("focal_length_35mm");
  out.metadata.gps.reset();
  if (flag_at("has_gps")) {
    GpsPosition gps;
    gps.latitude_degrees = number_at("gps_latitude");
    gps.longitude_degrees = number_at("gps_longitude");
    if (const auto* altitude = document.find("gps_altitude");
        altitude != nullptr && altitude->is_number()) {
      gps.altitude_metres = altitude->number();
    }
    out.metadata.gps = gps;
  }
  out.hdr_headroom = read_optional(document, "hdr_headroom").value_or(1.0F);
  out.capture.iso = read_optional(document, "capture_iso");
  out.capture.exposure_time_seconds =
      read_optional(document, "capture_exposure_time_seconds");
  out.capture.aperture_f_number = read_optional(document, "capture_aperture_f_number");
  out.decode.sensor_width =
      static_cast<std::uint32_t>(number_at("decode_sensor_width"));
  out.decode.sensor_height =
      static_cast<std::uint32_t>(number_at("decode_sensor_height"));
  out.decode.target_width =
      static_cast<std::uint32_t>(number_at("decode_target_width"));
  out.decode.target_height =
      static_cast<std::uint32_t>(number_at("decode_target_height"));
  out.decode.requested_crop_left =
      static_cast<std::uint32_t>(number_at("decode_requested_crop_left"));
  out.decode.requested_crop_top =
      static_cast<std::uint32_t>(number_at("decode_requested_crop_top"));
  out.decode.delivered_crop_left =
      static_cast<std::uint32_t>(number_at("decode_delivered_crop_left"));
  out.decode.delivered_crop_top =
      static_cast<std::uint32_t>(number_at("decode_delivered_crop_top"));
  out.decode.decoded_width =
      static_cast<std::uint32_t>(number_at("decode_decoded_width"));
  out.decode.decoded_height =
      static_cast<std::uint32_t>(number_at("decode_decoded_height"));
  out.decode.resolution_reduced = flag_at("decode_resolution_reduced");
  // Absent means "could not be confirmed", and for this predicate the
  // conservative reading is that target_* was not applied: a false negative
  // only costs a consumer one skipped ratio, a false positive invents one.
  const auto* applied = document.find("decode_target_dimensions_applied");
  out.decode.target_dimensions_applied =
      applied != nullptr && applied->is_bool() && applied->boolean();
  out.decode.default_crop_present = flag_at("decode_default_crop_present");
  out.decode.degraded = flag_at("decode_degraded");
  out.decode.degradation_reasons.clear();
  if (const auto* reasons = document.find("decode_degradation_reasons");
      reasons != nullptr && reasons->is_array()) {
    for (const auto& reason : reasons->array()) {
      if (reason.is_string()) out.decode.degradation_reasons.push_back(reason.string());
    }
  }
}

}  // namespace

std::string decode_cache_key(const std::filesystem::path& input,
                             std::string_view variant) {
  const auto absolute = std::filesystem::absolute(input).lexically_normal();
  std::error_code size_ec;
  const auto size = std::filesystem::file_size(absolute, size_ec);
  std::error_code time_ec;
  const auto modified = std::filesystem::last_write_time(absolute, time_ec);
  // Content hash, not just size and mtime.
  //
  // Path, size and modification time describe where a file is and when it was
  // touched, not what is in it, and every one of them survives a replacement:
  // restoring a backup, checking out a different revision, or any tool that
  // preserves timestamps produces a different photograph at the same identity,
  // and the cache would serve the previous one's pixels. Hashing costs a
  // sequential read of the source; the decode this avoids costs far more.
  std::string content;
  try {
    content = sha256_file_hex(absolute);
  } catch (const std::exception&) {
    // Unreadable here means the decode is about to fail anyway. Fall back to
    // a marker that cannot collide with a real digest so the entry is simply
    // never shared with a successfully hashed read.
    content = "unhashed";
  }
  const std::string identity =
      path_utf8(absolute) + '|' +
      std::to_string(size_ec ? 0ULL : static_cast<unsigned long long>(size)) + '|' +
      std::to_string(time_ec ? 0LL
                            : static_cast<long long>(modified.time_since_epoch().count())) +
      '|' + content + '|' + std::string(variant) + '|' + kVersion + '|' +
      std::to_string(kCacheSchema);
  return fnv1a_hex(identity);
}

std::filesystem::path decode_cache_path(const std::filesystem::path& directory,
                                        const std::string& key) {
  return directory / (key + ".hdrcache");
}

bool read_decode_cache(const std::filesystem::path& file, DecodedImage& out) {
  std::error_code ec;
  if (!std::filesystem::is_regular_file(file, ec) || ec) return false;
  std::ifstream input(file, std::ios::binary);
  if (!input) return false;
  std::array<std::uint8_t, 28> header{};
  input.read(reinterpret_cast<char*>(header.data()),
             static_cast<std::streamsize>(header.size()));
  if (input.gcount() != static_cast<std::streamsize>(header.size())) return false;
  if (std::memcmp(header.data(), kMagic.data(), kMagic.size()) != 0) return false;
  if (get_u32(header.data() + 8) != kCacheSchema) return false;

  const auto width = get_u32(header.data() + 12);
  const auto height = get_u32(header.data() + 16);
  const auto channels = get_u32(header.data() + 20);
  const auto json_length = get_u32(header.data() + 24);
  if (width == 0 || height == 0 || channels == 0 || channels > 4) return false;
  if (json_length > (1U << 20U)) return false;
  const auto pixel_count =
      static_cast<std::uint64_t>(width) * height * channels;
  if (pixel_count > (1ULL << 34U)) return false;

  std::string metadata_text(json_length, '\0');
  if (json_length != 0) {
    input.read(metadata_text.data(), static_cast<std::streamsize>(json_length));
    if (input.gcount() != static_cast<std::streamsize>(json_length)) return false;
  }

  DecodedImage loaded;
  try {
    loaded.linear_p3 = FloatImage(width, height, channels);
    if (json_length != 0) apply_metadata_json(metadata_text, loaded);
  } catch (const std::exception&) {
    return false;
  }
  const auto bytes = static_cast<std::streamsize>(pixel_count * sizeof(float));
  input.read(reinterpret_cast<char*>(loaded.linear_p3.pixels.data()), bytes);
  if (input.gcount() != bytes) return false;
  out = std::move(loaded);
  return true;
}

bool write_decode_cache(const std::filesystem::path& file, const DecodedImage& value,
                        std::uint64_t budget_bytes) {
  const auto& image = value.linear_p3;
  if (image.width == 0 || image.height == 0 || image.channels == 0) return false;
  if (!image.is_consistent()) return false;
  try {
    std::filesystem::create_directories(file.parent_path());
    const auto metadata = metadata_json(value);
    std::vector<std::uint8_t> bytes;
    bytes.reserve(28 + metadata.size() + image.pixels.size() * sizeof(float));
    bytes.insert(bytes.end(), kMagic.begin(), kMagic.end());
    put_u32(bytes, kCacheSchema);
    put_u32(bytes, image.width);
    put_u32(bytes, image.height);
    put_u32(bytes, image.channels);
    put_u32(bytes, static_cast<std::uint32_t>(metadata.size()));
    bytes.insert(bytes.end(), metadata.begin(), metadata.end());
    const auto* raw = reinterpret_cast<const std::uint8_t*>(image.pixels.data());
    bytes.insert(bytes.end(), raw, raw + image.pixels.size() * sizeof(float));
    write_binary_file_atomic(file, bytes, true);
    // The budget is enforced here, on every write, not only once before a
    // batch starts. Pruning at the start bounds what a batch inherits and
    // nothing at all about what it adds, so a long --recursive run could leave
    // the directory arbitrarily far over its limit. Entries are removed
    // oldest-first, so the one just written is the last candidate.
    if (budget_bytes != 0) {
      prune_decode_cache(file.parent_path(), budget_bytes);
    }
    return true;
  } catch (const std::exception&) {
    return false;
  }
}

void prune_decode_cache(const std::filesystem::path& directory,
                        std::uint64_t budget_bytes) {
  std::error_code ec;
  if (!std::filesystem::is_directory(directory, ec) || ec) return;
  struct Entry {
    std::filesystem::path path;
    std::uint64_t size{};
    std::filesystem::file_time_type modified{};
  };
  std::vector<Entry> entries;
  std::uint64_t total = 0;
  for (const auto& item : std::filesystem::directory_iterator(directory, ec)) {
    if (ec) return;
    if (!item.is_regular_file() || item.path().extension() != ".hdrcache") continue;
    std::error_code size_ec;
    const auto size = std::filesystem::file_size(item.path(), size_ec);
    if (size_ec) continue;
    std::error_code time_ec;
    const auto modified = std::filesystem::last_write_time(item.path(), time_ec);
    if (time_ec) continue;
    entries.push_back({item.path(), static_cast<std::uint64_t>(size), modified});
    total += static_cast<std::uint64_t>(size);
  }
  if (total <= budget_bytes) return;
  std::sort(entries.begin(), entries.end(),
            [](const Entry& a, const Entry& b) { return a.modified < b.modified; });
  for (const auto& entry : entries) {
    if (total <= budget_bytes) break;
    std::error_code remove_ec;
    if (std::filesystem::remove(entry.path, remove_ec) && !remove_ec) {
      total -= std::min(total, entry.size);
    }
  }
}

}  // namespace hyperdr

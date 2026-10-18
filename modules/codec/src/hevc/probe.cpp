#include "hevc/vt_common.hpp"

#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/json.hpp"

#include <VideoToolbox/VideoToolbox.h>
#include <sys/sysctl.h>

#include <cmath>
#include <mutex>
#include <optional>
#include <set>

namespace hyperdr::codec::hevc {
namespace {

// Hidden, so the app's cache trimming (which skips hidden files) leaves it
// alone; the engine's own pruning only touches `.hdrcache` files.
constexpr const char* kCacheFile = ".hevc-encoder-caps.json";
constexpr int kCacheFormat = 1;

struct CacheState {
  std::mutex mutex;
  std::optional<EncoderCaps> caps;
  // Every directory used by any engine in this process must be invalidated.
  std::set<std::filesystem::path> files;
};

CacheState& cache() {
  static CacheState state;
  return state;
}

std::string os_build() {
  char buffer[64] = {};
  std::size_t size = sizeof(buffer);
  if (sysctlbyname("kern.osversion", buffer, &size, nullptr, 0) != 0 || size == 0) return {};
  return std::string(buffer, strnlen(buffer, sizeof(buffer)));
}

// A smooth two-axis ramp with a fine diagonal pattern: smooth enough to verify
// with a strict PSNR, varied enough that a 10-bit encode has to keep its low
// bits.
YuvTile synthetic_tile(int bit_depth) {
  auto tile = make_tile(bit_depth);
  const unsigned max_code = (1U << static_cast<unsigned>(bit_depth)) - 1U;
  const auto put = [&](std::vector<std::uint8_t>& plane, std::size_t index, unsigned code) {
    if (bit_depth > 8) {
      const unsigned word = code << 6U;
      plane[index * 2] = static_cast<std::uint8_t>(word & 0xFFU);
      plane[index * 2 + 1] = static_cast<std::uint8_t>(word >> 8U);
    } else {
      plane[index] = static_cast<std::uint8_t>(code);
    }
  };
  for (std::uint32_t y = 0; y < kTileSize; ++y) {
    for (std::uint32_t x = 0; x < kTileSize; ++x) {
      const double value = 0.1 + 0.6 * (x + y) / (2.0 * kTileSize) +
                           0.02 * std::sin((x + 2.0 * y) * 0.05);
      put(tile.luma, static_cast<std::size_t>(y) * kTileSize + x,
          static_cast<unsigned>(std::lround(value * max_code)));
    }
  }
  for (std::uint32_t y = 0; y < kTileSize / 2; ++y) {
    for (std::uint32_t x = 0; x < kTileSize / 2; ++x) {
      const std::size_t at = (static_cast<std::size_t>(y) * (kTileSize / 2) + x) * 2;
      put(tile.chroma, at, static_cast<unsigned>(std::lround((0.4 + 0.2 * x / kTileSize) * max_code)));
      put(tile.chroma, at + 1, static_cast<unsigned>(std::lround((0.6 - 0.2 * y / kTileSize) * max_code)));
    }
  }
  return tile;
}

// general_profile_idc: SPS NAL header (2 bytes), then one byte of
// vps id / max sub-layers / nesting, then profile_space(2) tier(1) idc(5). No
// emulation-prevention byte can occur this early.
int sps_profile(const std::vector<std::uint8_t>& sps) {
  return sps.size() > 3 ? sps[3] & 0x1F : -1;
}

// Encodes and decodes one tile and checks what came back. Throws VtError for
// VideoToolbox failures and std::runtime_error when the round trip does not
// verify.
void round_trip(int bit_depth) {
  const auto source = synthetic_tile(bit_depth);
  EncodeParams params;
  params.quality = 90;
  params.main10 = bit_depth > 8;
  params.color = {1, 1, 1};
  const auto sequence = encode_sequence(
      1, [&](std::size_t, YuvTile& tile) { tile = source; }, params, false);
  if (sequence.samples.size() != 1) throw std::runtime_error("probe returned no picture");
  const int expected_profile = bit_depth > 8 ? 2 : 1;
  if (sps_profile(sequence.sps) != expected_profile) {
    throw std::runtime_error("probe SPS signals profile " + std::to_string(sps_profile(sequence.sps)));
  }
  const auto decoded = decode(sequence, bit_depth);
  const unsigned max_code = (1U << static_cast<unsigned>(bit_depth)) - 1U;
  double squared = 0.0;
  bool low_bits = false;
  for (std::uint32_t y = 0; y < kTileSize; ++y) {
    for (std::uint32_t x = 0; x < kTileSize; ++x) {
      const double a = source.luma_at(x, y);
      const unsigned b = decoded[0].luma_at(x, y);
      squared += (a - b) * (a - b);
      low_bits = low_bits || (b & 3U) != 0;
    }
  }
  const double mse = squared / (static_cast<double>(kTileSize) * kTileSize);
  const double psnr = mse == 0.0 ? 99.0 : 10.0 * std::log10(max_code * max_code / mse);
  if (psnr < 35.0) {
    throw std::runtime_error("probe round trip PSNR " + std::to_string(psnr) + " dB");
  }
  if (bit_depth > 8 && !low_bits) throw std::runtime_error("Main10 probe decoded only 8-bit codes");
}

bool encoder_missing(const VtError& error) {
  return error.status() == kVTCouldNotFindVideoEncoderErr ||
         error.status() == kVTVideoEncoderNotAvailableNowErr;
}

EncoderCaps probe() {
  EncoderCaps caps;
  try {
    round_trip(8);
    caps.main8 = true;
  } catch (const Cancelled&) {
    throw;
  } catch (const VtError& error) {
    caps.reason_code = encoder_missing(error) ? kReasonUnavailable : kReasonProbeFailed;
    caps.detail = std::string("8-bit: ") + error.what();
    return caps;
  } catch (const std::exception& error) {
    caps.reason_code = kReasonProbeFailed;
    caps.detail = std::string("8-bit: ") + error.what();
    return caps;
  }
  try {
    round_trip(10);
    caps.main10 = true;
  } catch (const Cancelled&) {
    throw;
  } catch (const std::exception& error) {
    caps.reason_code = kReasonMain10Unavailable;
    caps.detail = std::string("Main10: ") + error.what();
  }
  return caps;
}

std::optional<EncoderCaps> read_cached(const std::filesystem::path& file, const std::string& build) {
  try {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(file, ec) || ec) return std::nullopt;
    const auto bytes = read_binary_file(file);
    if (bytes.size() > 4096) return std::nullopt;
    const auto value = json::parse(std::string(bytes.begin(), bytes.end()));
    const auto* format = value.find("format");
    const auto* system = value.find("os_build");
    const auto* main8 = value.find("main8");
    const auto* main10 = value.find("main10");
    if (!format || !format->is_number() || format->number() != kCacheFormat || !system ||
        !system->is_string() || system->string() != build || !main8 || !main8->is_bool() ||
        !main10 || !main10->is_bool() || !main8->boolean() || !main10->boolean()) {
      return std::nullopt;
    }
    EncoderCaps caps;
    caps.main8 = caps.main10 = true;
    caps.detail = "cached";
    return caps;
  } catch (const std::exception&) {
    return std::nullopt;  // a damaged cache is a miss
  }
}

void write_cached(const std::filesystem::path& file, const std::string& build) {
  try {
    std::filesystem::create_directories(file.parent_path());
    write_text_file_atomic(file,
                           "{\"format\":" + std::to_string(kCacheFormat) + ",\"os_build\":\"" +
                               json::escape(build) + "\",\"main8\":true,\"main10\":true}\n",
                           true);
  } catch (const std::exception&) {
    // An unwritable cache only costs a probe in the next process.
  }
}

}  // namespace

EncoderCaps encoder_caps(const std::filesystem::path& cache_directory) {
  auto& state = cache();
  std::lock_guard lock(state.mutex);  // one probe, however many first callers
  const auto build = os_build();
  std::filesystem::path file;
  if (!cache_directory.empty() && !build.empty()) {
    std::error_code ec;
    const auto absolute = std::filesystem::absolute(cache_directory, ec);
    if (!ec) {
      // Resolve existing symlinks before removing '..', and retain the real
      // directory even if an alias is later retargeted. Missing suffixes are
      // allowed: write_cached creates them. Resolution failure disables only
      // the disk cache, never the capability probe.
      const auto directory = std::filesystem::weakly_canonical(absolute, ec);
      if (!ec) file = directory / kCacheFile;
    }
  }
  if (!state.caps && !file.empty()) {
    if (auto cached = read_cached(file, build)) {
      state.caps = std::move(cached);
      state.files.insert(file);
    }
  }
  if (!state.caps) state.caps = probe();
  const bool ready = state.caps->main8 && state.caps->main10;
  if (ready && !file.empty() && !state.files.contains(file)) {
    write_cached(file, build);
    state.files.insert(file);
  }
  return *state.caps;
}

void invalidate_encoder_caps() {
  auto& state = cache();
  std::lock_guard lock(state.mutex);
  state.caps.reset();
  for (const auto& file : state.files) {
    std::error_code ec;
    std::filesystem::remove(file, ec);
  }
  state.files.clear();
}

}  // namespace hyperdr::codec::hevc

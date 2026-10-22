#include <mach/mach.h>
#include <unistd.h>

#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fstream>
#include <iostream>
#include <thread>

#include "hevc/testing.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
namespace {
void check_diagnostic_modes() {
  namespace h = hyperdr::codec::hevc;
  h::DecodedPicture p{4, 1, 10, 2, {}, {}};
  const auto word = [](std::vector<std::uint8_t>& out, unsigned value) {
    const std::uint16_t v = value << 6;
    const auto* first = reinterpret_cast<const std::uint8_t*>(&v);
    out.insert(out.end(), first, first + 2);
  };
  for (int i = 0; i < 4; ++i) word(p.luma, 512);
  for (unsigned v : {512U, 512U, 513U, 512U}) word(p.chroma, v);
  h::YuvRgbParams params;
  params.matrix = 9;
  params.full_range = true;
  params.parallel_rows = false;
  const auto convert = [&] {
    std::vector<float> result;
    h::yuv_to_rgb(p, params, [&](unsigned, auto row) { result.assign(row.begin(), row.end()); });
    return result;
  };
  const auto original = convert();
  h::testing::set_nearest_chroma(true);
  const auto nearest = convert();
  h::testing::set_nearest_chroma(false);
  h::testing::set_rounded_chroma(true);
  const auto rounded = convert();
  h::testing::set_rounded_chroma(false);
  if (std::abs(original[8] * 1023 - 513.41105F) > .0002F ||
      std::abs(nearest[8] * 1023 - 513.8814F) > .0002F || nearest != rounded ||
      convert() != original)
    throw std::runtime_error("diagnostic mode did not isolate chroma sampling");
}
// This executable links its own diagnostic yuv_to_rgb object next to the codec
// library, which carries the product's object with the same symbols. The link
// resolves them to one definition only because the library's copy is never
// pulled in; prove that the library's HEIC decoder runs the diagnostic one, so
// a link-order change cannot silently turn the switches into no-ops.
void check_library_path_uses_diagnostic_object() {
  hyperdr::PhotoRenditions photo;
  photo.hdr = hyperdr::FloatImage(64, 64, 3);
  for (unsigned y = 0; y < 64; ++y)
    for (unsigned x = 0; x < 64; ++x) {
      photo.hdr.at(x, y, 0) = .02F + .9F * float(x) / 63;
      photo.hdr.at(x, y, 1) = .02F + .9F * float(y) / 63;
      photo.hdr.at(x, y, 2) = ((x / 3 + y / 3) % 2) ? .8F : .05F;  // chroma edges
    }
  photo.stats.headroom_stops = 1;
  const auto path = std::filesystem::temp_directory_path() /
                    ("heif-input-probe-self-test-" + std::to_string(::getpid()) + ".heic");
  hyperdr::write_binary_file_atomic(
      path, hyperdr::encode_hdr_heic(photo, {}, 95, hyperdr::HdrEncoding::Pq), true);
  try {
    const auto normal = hyperdr::decode_image(path).linear_p3.pixels;
    hyperdr::codec::hevc::testing::set_nearest_chroma(true);
    const auto nearest = hyperdr::decode_image(path).linear_p3.pixels;
    hyperdr::codec::hevc::testing::set_nearest_chroma(false);
    if (hyperdr::decode_image(path).linear_p3.pixels != normal || nearest == normal)
      throw std::runtime_error("the codec library's HEIC decoder does not run the diagnostic conversion");
  } catch (...) {
    hyperdr::codec::hevc::testing::set_nearest_chroma(false);
    std::filesystem::remove(path);
    throw;
  }
  std::filesystem::remove(path);
}
}  // namespace
int main(int argc, char** argv) {
  try {
    if (argc == 2 && std::string_view(argv[1]) == "--self-test") {
      check_diagnostic_modes();
      check_library_path_uses_diagnostic_object();
      return 0;
    }
    if (argc < 3 || argc > 6) return 2;
    bool metadata_only = false, nearest = false, rounded = false, integer = false;
    for (int i = 3; i < argc; ++i) {
      std::string_view option = argv[i];
      if (option == "--nearest-chroma")
        nearest = true;
      else if (option == "--rounded-chroma")
        rounded = true;
      else if (option == "--integer-rgb")
        integer = true;
      else if (option == "--metadata-only")
        metadata_only = true;
      else
        return 2;
    }
    if (nearest && rounded) throw std::invalid_argument("select one chroma diagnostic mode");
    hyperdr::codec::hevc::testing::set_nearest_chroma(nearest);
    hyperdr::codec::hevc::testing::set_rounded_chroma(rounded);
    hyperdr::codec::hevc::testing::set_integer_rgb(integer);
    std::atomic<bool> stop = false;
    std::atomic<unsigned long long> peak = 0;
    std::thread sampler([&] {
      while (!stop) {
        task_vm_info_data_t info{};
        mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &n) ==
            KERN_SUCCESS) {
          auto old = peak.load();
          while (old < info.phys_footprint &&
                 !peak.compare_exchange_weak(old, info.phys_footprint)) {
          }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
      }
    });
    auto start = std::chrono::steady_clock::now();
    hyperdr::DecodedImage d;
    try {
      d = hyperdr::decode_image(argv[1]);
    } catch (...) {
      stop = true;
      sampler.join();
      throw;
    }
    auto ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    stop = true;
    sampler.join();
    std::filesystem::path out = argv[2];
    std::filesystem::create_directories(out);
    auto dump = [&](const char* name, const hyperdr::FloatImage& im) {
      std::ofstream f(out / name, std::ios::binary);
      f.write(reinterpret_cast<const char*>(im.pixels.data()), im.pixels.size() * sizeof(float));
      if (!f) throw std::runtime_error("write failed");
    };
    if (!metadata_only) {
      dump("linear_p3.f32", d.linear_p3);
      if (d.authored_sdr) dump("authored_sdr.f32", *d.authored_sdr);
    }
    hyperdr::json::Writer j;
    j.begin_object()
        .member("decode_ms", ms)
        .member("peak_footprint", peak.load())
        .member("source", argv[1])
        .member("width", d.linear_p3.width)
        .member("height", d.linear_p3.height)
        .member("channels", d.linear_p3.channels)
        .member("headroom", d.hdr_headroom)
        .member("has_authored_sdr", bool(d.authored_sdr))
        .member("gain_base_headroom", d.gain_map.base_headroom)
        .member("gain_alternate_headroom", d.gain_map.alternate_headroom)
        .member("source_name", d.source_color.name)
        .member("source_primaries", d.source_color.primaries)
        .member("source_transfer", d.source_color.transfer)
        .member("source_backend", d.source_color.source)
        .member("domain", hyperdr::input_domain_name(d.domain))
        .member("orientation", d.metadata.orientation)
        .member("content_peak_nits", d.content_peak_nits)
        .member("degraded", d.decode.degraded)
        .member("headroom_float_bits", std::bit_cast<std::uint32_t>(d.hdr_headroom))
        .member("gain_base_headroom_bits", std::bit_cast<std::uint32_t>(d.gain_map.base_headroom))
        .member("gain_alternate_headroom_bits",
                std::bit_cast<std::uint32_t>(d.gain_map.alternate_headroom))
        .member("gain_channels", d.gain_map.channels);
    j.begin_array("base_offsets");
    for (auto n : d.gain_map.base_offset) j.element(n);
    j.end_array().begin_array("alternate_offsets");
    for (auto n : d.gain_map.alternate_offset) j.element(n);
    j.end_array().begin_array("degradation_reasons");
    for (const auto& n : d.decode.degradation_reasons) j.element(n);
    j.end_array().end_object();
    auto text = j.take();
    std::ofstream(out / "metadata.json") << text << '\n';
    std::cout << text << '\n';
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}

#include "cli_commands.hpp"

#include "hyperdr/app/preview.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/resample.hpp"

#include <cmath>
#include <algorithm>
#include <iomanip>
#include <iostream>
#include <utility>

namespace hyperdr::app::detail {

int probe_command(int argc, char** argv) {
  if (argc < 3 || argc > 4) throw std::invalid_argument("probe requires one input image");
  if (argc == 4 && std::string_view(argv[3]) != "--json") {
    throw std::invalid_argument("unknown probe option: " + std::string(argv[3]));
  }
  set_stdout_binary();
  std::cout << Engine().probe(path_from_utf8(argv[2]));
  return 0;
}

void print_inspection(const HeifInspection& i) {
  std::cout << "structurally valid: " << (i.structurally_valid ? "yes" : "no") << '\n'
            << "HEIC brand: " << (i.has_heic_brand ? "yes" : "no") << '\n'
            << "TMAP brand/item: " << (i.has_tmap_brand ? "yes" : "no") << '/'
            << (i.has_tmap_item ? "yes" : "no") << '\n'
            << "dimg/altr: " << (i.has_dimg_reference ? "yes" : "no") << '/'
            << (i.has_altr_group ? "yes" : "no") << '\n'
            << "primary item: " << i.primary_item_id << '\n';
  for (const auto& error : i.errors) std::cout << "error: " << error << '\n';
  for (const auto& box : i.boxes) {
    std::cout << std::string(box.depth * 2, ' ') << box.type << " @" << box.offset
              << " (" << box.size << ")\n";
  }
}

int inspect_command(int argc, char** argv) {
  if (argc < 3 || argc > 4) throw std::invalid_argument("inspect requires one HEIC or gain-map JPEG path");
  if (argc == 4 && std::string_view(argv[3]) != "--json")
    throw std::invalid_argument("unknown inspect option: " + std::string(argv[3]));
  const auto bytes = read_binary_file(path_from_utf8(argv[2]));
  if (bytes.size() >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    try {
    const auto segments = inspect_gain_map_jpeg(bytes);
    const bool duplicate = segments.primary_iso_count>1 || segments.gain_iso_count>1;
    const bool iso = segments.primary_iso_count && segments.gain_iso_count && !duplicate;
    const auto parsed = iso ? parse_gain_map_jpeg_input(bytes) : segments;
    json::Writer writer;
    writer.begin_object().member("structurally_valid", !duplicate)
        .member("reader_path", duplicate ? "sdr-fallback" : iso ? "iso-own" : "xmp-libultrahdr")
        .member("degradation_reason", duplicate ? "gain_map_metadata_duplicate" : "")
        .member("mpf_repaired", parsed.repaired_mpf)
        .member("mpf_diagnostic", parsed.repaired_mpf ? "MPF offset or length disagrees with JPEG boundaries; using actual JPEG boundaries" : "")
        .member("trailing_bytes", parsed.trailing_bytes)
        .member("trailing_diagnostic", parsed.trailing_bytes ? "File ends with unrecognized additional data (length recorded in trailing_bytes)" : "")
        .member("primary_iso_segments", parsed.primary_iso_count)
        .member("gain_iso_segments", parsed.gain_iso_count)
        .member("mpf_segments", parsed.mpf_count)
        .member("primary_size", parsed.primary_size)
        .member("gain_offset", parsed.gain_offset)
        .member("gain_size", parsed.gain_size);
    if(!iso) {
      writer.member("has_hdrgm",parsed.has_hdrgm).member("has_container_directory",parsed.has_container_directory).end_object();
      std::cout<<writer.take()<<'\n';return 0;
    }
    writer.member("base_headroom", static_cast<double>(rational_value(parsed.metadata.base_headroom)))
        .member("alternate_headroom", static_cast<double>(rational_value(parsed.metadata.alternate_headroom)))
        .member("channels", gain_map_channel_count(parsed.metadata))
        .member("has_hdrgm", parsed.has_hdrgm)
        .member("has_container_directory", parsed.has_container_directory)
        .begin_array("channel_metadata");
    for (std::size_t i = 0; i < gain_map_channel_count(parsed.metadata); ++i) {
      const auto channel = gain_map_channel(parsed.metadata, i);
      writer.begin_object().member("gain_min", static_cast<double>(rational_value(channel.gain_min)))
          .member("gain_max", static_cast<double>(rational_value(channel.gain_max)))
          .member("gamma", static_cast<double>(rational_value(channel.gamma)))
          .member("base_offset", static_cast<double>(rational_value(channel.base_offset)))
          .member("alternate_offset", static_cast<double>(rational_value(channel.alternate_offset))).end_object();
    }
    writer.end_array().end_object();
    std::cout << writer.take() << '\n';
    return 0;
    } catch(const Cancelled&) { throw; }
      catch(const std::exception& error) {
        json::Writer writer;
        writer.begin_object().member("structurally_valid",false).member("reader_path","sdr-fallback")
            .member("degradation_reason",error.what()).end_object();
        std::cout<<writer.take()<<'\n';return 0;
      }
  }
  const auto inspection = inspect_heif(bytes);
  if (argc == 4) {
    if (std::string_view(argv[3]) != "--json") {
      throw std::invalid_argument("unknown inspect option: " + std::string(argv[3]));
    }
    std::cout << inspection_json(inspection) << '\n';
  } else {
    print_inspection(inspection);
  }
  return inspection.structurally_valid ? 0 : 1;
}

// What a viewer of `candidate` sees compared with `reference`, both decoded the
// way every other command decodes them: a gain map is applied at its full
// alternate headroom and PQ/HLG are read through their exact inverses, so an
// HDR source and its gain-map conversion meet in the same linear P3 space.
void print_fidelity(const std::filesystem::path& reference,
                    const std::filesystem::path& candidate) {
  if (same_path(reference, candidate)) {
    throw std::invalid_argument("--reference must name a different file");
  }
  const RawDecodeOptions decode{};
  auto source = decode_image(reference, decode);
  auto converted = decode_image(candidate, decode);
  const auto result = measure_hdr_fidelity(source.linear_p3, converted.linear_p3);
  const auto stops = [](float peak) { return std::log2(std::max(peak, 1.0e-6F)); };
  const auto flags = std::cout.flags();
  const auto precision = std::cout.precision();
  std::cout << std::fixed << std::setprecision(3)
            << "reference: " << path_utf8(reference) << " ("
            << input_domain_name(source.domain) << ")\n"
            << "candidate domain: " << input_domain_name(converted.domain) << '\n'
            << "compared pixels: " << result.pixels << '\n'
            << "delta E ITP mean/p50/p95/p99/p99.9/max: " << result.delta_e_itp_mean
            << " / " << result.delta_e_itp_p50 << " / " << result.delta_e_itp_p95
            << " / " << result.delta_e_itp_p99 << " / " << result.delta_e_itp_p999
            << " / " << result.delta_e_itp_max << '\n'
            << "pixels above delta E ITP 1/2/5: " << 100.0 * result.fraction_above_1
            << "% / " << 100.0 * result.fraction_above_2 << "% / "
            << 100.0 * result.fraction_above_5 << "%\n"
            << "delta E ITP mean in shadows/midtones/highlights: "
            << result.band_delta_e_itp_mean[0] << " / " << result.band_delta_e_itp_mean[1]
            << " / " << result.band_delta_e_itp_mean[2] << " (pixels "
            << result.band_pixels[0] << " / " << result.band_pixels[1] << " / "
            << result.band_pixels[2] << ")\n"
            << "PSNR (PQ, BT.2020): ";
  if (std::isinf(result.psnr_pq_db)) std::cout << "identical\n";
  else std::cout << result.psnr_pq_db << " dB\n";
  std::cout << "peak luminance reference/candidate: " << result.reference_peak << " ("
            << stops(result.reference_peak) << " stops) / " << result.candidate_peak << " ("
            << stops(result.candidate_peak) << " stops)\n"
            << "mean luminance reference/candidate: " << result.reference_mean << " / "
            << result.candidate_mean << '\n';
  // The same comparison after averaging 4x4 blocks in linear light. Per-pixel
  // ΔE ITP counts the dither grain of an 8-bit base in the deepest shadows as
  // colour error at full weight, although no display shows a camera frame at
  // 1:1 and grain that fine averages out before anyone sees it. The quarter
  // scale is still larger than any screen the photograph is viewed on; a tonal
  // or colour shift survives the averaging and grain does not, which is the
  // distinction the full-resolution figures above cannot make.
  constexpr std::uint32_t kViewingScale = 4;
  const auto width = source.linear_p3.width / kViewingScale;
  const auto height = source.linear_p3.height / kViewingScale;
  if (width >= 256 && height >= 256) {
    const auto viewed = measure_hdr_fidelity(
        resample_to(std::move(source.linear_p3), width, height),
        resample_to(std::move(converted.linear_p3), width, height));
    std::cout << "at 1/" << kViewingScale << " scale (" << width << 'x' << height
              << ", 4x4 linear means) delta E ITP mean/p99/p99.9: "
              << viewed.delta_e_itp_mean << " / " << viewed.delta_e_itp_p99 << " / "
              << viewed.delta_e_itp_p999 << ", shadows/midtones/highlights: "
              << viewed.band_delta_e_itp_mean[0] << " / " << viewed.band_delta_e_itp_mean[1]
              << " / " << viewed.band_delta_e_itp_mean[2] << ", PSNR: ";
    if (std::isinf(viewed.psnr_pq_db)) std::cout << "identical\n";
    else std::cout << viewed.psnr_pq_db << " dB\n";
  }
  std::cout.flags(flags);
  std::cout.precision(precision);
}

int verify_command(int argc, char** argv) {
  if (argc < 3) {
    throw std::invalid_argument("verify requires one HEIC, JPEG, or TIFF path");
  }
  const std::filesystem::path input = path_from_utf8(argv[2]);
  std::filesystem::path reconstruct;
  std::filesystem::path reference;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--reconstruct") reconstruct = path_from_utf8(next_value(i, argc, argv, arg));
    else if (arg == "--reference") reference = path_from_utf8(next_value(i, argc, argv, arg));
    else throw std::invalid_argument("unknown verify option: " + std::string(arg));
  }

  const auto extension = lower_extension(input);
  if (extension == ".tif" || extension == ".tiff") {
    if (!reconstruct.empty()) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    verify_sdr_tiff(read_binary_file(input));
    std::cout << "SDR TIFF: yes\n";
    if (!reference.empty()) print_fidelity(reference, input);
    std::cout << "verification passed\n";
    return 0;
  }
  if (extension == ".jpg" || extension == ".jpeg") {
    if (!reconstruct.empty()) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    const auto bytes = read_binary_file(input);
    // Searched without the terminating NUL. An Ultra HDR v1 file describes its
    // gain map only in `hdrgm` XMP, which this program no longer writes.
    const auto contains = [&](std::string_view text) {
      return std::search(bytes.begin(), bytes.end(), text.begin(), text.end()) != bytes.end();
    };
    if (contains("urn:iso:std:iso:ts:21496:-1")) {
      verify_gain_map_jpeg(bytes);
      std::cout << "ISO gain-map JPEG: yes\n";
    } else if (contains("http://ns.adobe.com/hdr-gain-map/1.0/")) {
      throw std::invalid_argument("not an ISO gain-map JPEG: the gain map is described only in XMP");
    } else {
      verify_sdr_jpeg(bytes);
      std::cout << "SDR JPEG: yes\n";
    }
    if (!reference.empty()) print_fidelity(reference, input);
    std::cout << "verification passed\n";
    return 0;
  }

  const auto inspection = inspect_heif(read_binary_file(input));
  const bool adaptive = inspection.has_tmap_brand || inspection.has_tmap_item;
  const bool adaptive_valid =
      !adaptive || (inspection.has_tmap_brand && inspection.has_tmap_item &&
                    inspection.has_dimg_reference && inspection.has_altr_group);
  print_inspection(inspection);
  if (!(inspection.structurally_valid && inspection.has_heic_brand && adaptive_valid)) {
    std::cout << "verification failed\n";
    return 1;
  }
  if (!reconstruct.empty()) {
    if (!adaptive) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    if (same_path(input, reconstruct)) {
      throw std::invalid_argument("reconstruction output must differ from input HEIC");
    }
    reconstruct_heic_to_tiff(input, reconstruct);
    std::cout << "reconstructed preview: " << path_utf8(reconstruct) << '\n';
  } else {
    verify_heic_decodable(input);
    std::cout << (adaptive ? "base/Gain Map decode: passed\n"
                           : "BT.2100 HDR decode: passed\n");
  }
  if (!reference.empty()) print_fidelity(reference, input);
  std::cout << "verification passed\n";
  return 0;
}

int thumbnail_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("thumbnail requires one input image");
  std::filesystem::path output;
  std::uint32_t max_edge = 2048;
  int quality = 85;
  bool model_input = false;
  // A preview that ignores the RAW decode settings is a preview of a different
  // photograph, so the caller passes the ones it is about to convert with.
  RawDecodeOptions raw;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--output") output = path_from_utf8(next_value(i, argc, argv, arg));
    else if (arg == "--max-edge") {
      max_edge = integer<std::uint32_t>(next_value(i, argc, argv, arg), "preview max edge");
    } else if (arg == "--quality") {
      quality = integer<int>(next_value(i, argc, argv, arg), "preview quality");
      if (quality < 1 || quality > 100) {
        throw std::invalid_argument("preview quality must be in [1,100]");
      }
    } else if (arg == "--highlight-recovery") {
      const std::string name(next_value(i, argc, argv, arg));
      const auto mode = highlight_recovery_from_name(name);
      if (!mode) throw std::invalid_argument("unknown highlight recovery: " + name);
      raw.highlight_recovery = *mode;
    } else if (arg == "--half-size") {
      // The preview is bounded by --max-edge anyway, so half-size demosaic
      // costs nothing visible and roughly quarters the decode.
      raw.half_size = true;
    } else if (arg == "--base-only") {
      raw.ignore_embedded_gain_map = true;
    } else if (arg == "--model-input") {
      model_input = true;
    } else if (arg == "--raw-bad-pixels") {
      raw.bad_pixel_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-dark-frame") {
      raw.dark_frame = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-linearization-lut") {
      raw.linearization_lut = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-profile") {
      raw.profile = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-lens-profile") {
      raw.lens_profile = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-lens-shading") {
      raw.lens_shading_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-auto-bad-pixels") {
      raw.auto_bad_pixel_correction = true;
    } else if (arg == "--raw-gain") {
      raw.digital_gain = real(next_value(i, argc, argv, arg), "RAW digital gain");
    } else {
      throw std::invalid_argument("unknown thumbnail option: " + std::string(arg));
    }
  }
  if (output.empty()) throw std::invalid_argument("thumbnail --output is required");
  const std::filesystem::path input = path_from_utf8(argv[2]);
  if (same_path(input, output)) {
    throw std::invalid_argument("thumbnail output must differ from input image");
  }
  const auto preview =
      encode_preview_jpeg(input, max_edge, quality, raw, model_input);
  write_binary_file_atomic(output, preview.bytes, true);
  // The JPEG alone is not the whole answer for an HDR input: it holds the
  // picture divided by `scale`, and a viewer that multiplies back by it sees the
  // highlights the file actually contains instead of a clipped white. Reported
  // on stdout as JSON for the same reason `curve` and `schema` are -- the file
  // is the output, so anything about it belongs in the stream beside it. RAW
  // also reports the automatic scene exposure that the browser must apply
  // before the user's brightness bias.
  std::cout << "{\"scale\":" << preview.scale
            << ",\"exposure\":" << preview.exposure_ev << "}\n";
  return 0;
}

int raw_metadata_command(int argc, char** argv) {
  if (argc != 3) throw std::invalid_argument("raw-metadata requires one RAW path");
  std::cout << Engine().raw_metadata(path_from_utf8(argv[2]));
  return 0;
}

}  // namespace hyperdr::app::detail

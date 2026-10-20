// Write-time HEIC verification on the native reader, no third-party decoder: files our
// own writer produced are accepted, and each rule the verifier enforces rejects
// a file that breaks only that rule. Also: the diagnostics (--reconstruct,
// display-curve) see the whole canvas or stop, never a reduced copy (R7-1101).
#include <algorithm>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include "../../../tests/support/temp_directory.hpp"
#include "heif_fixture_edit.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hevc/hevc.hpp"
#include "internal/heif_decoder.hpp"
#include "internal/icc_profiles.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "../../../tests/support/writer_planes.hpp"
using namespace hyperdr;
namespace {
using Bytes = std::vector<std::uint8_t>;
using heif_fixture::Box;
void require(bool ok, const std::string& message) {
  if (!ok) throw std::runtime_error(message);
}
GainMapResult make_gain(unsigned width, unsigned height) {
  GainMapResult result;
  result.base_linear = FloatImage(width, height, 3);
  for (unsigned y = 0; y < height; ++y)
    for (unsigned x = 0; x < width; ++x)
      for (unsigned c = 0; c < 3; ++c)
        result.base_linear.at(x, y, c) = .05F + .6F * float((x * 3 + y * 5 + c) % 97) / 96.F;
  result.gain_map = FloatImage((width + 1) / 2, (height + 1) / 2, 1);
  for (unsigned i = 0; i < result.gain_map.pixels.size(); ++i)
    result.gain_map.pixels[i] = float(i % 17) / 16.F;
  result.metadata.gain_max = {2, 1};
  result.metadata.alternate_headroom = {2, 1};
  result.headroom_stops = 2.F;
  return result;
}
// A rejection must name its cause: the substring is what the user would read.
void rejects(const char* name, const std::function<void()>& verify, const char* needle) {
  try {
    verify();
  } catch (const std::exception& error) {
    if (needle && std::string(error.what()).find(needle) == std::string::npos)
      throw std::runtime_error(std::string(name) + " was rejected for another reason: " + error.what());
    return;
  }
  throw std::runtime_error(std::string(name) + " was accepted");
}
Bytes with_boxes(const Bytes& bytes, const std::function<void(std::vector<Box>&)>& edit) {
  return heif_fixture::edit(bytes, edit);
}
void replace_text(Bytes& data, const std::string& from, const std::string& to) {
  require(from.size() == to.size(), "replacement must keep the size");
  const auto at = std::search(data.begin(), data.end(), from.begin(), from.end());
  require(at != data.end(), "text to replace is missing: " + from);
  std::copy(to.begin(), to.end(), at);
}
// Every property of the given type (in item order); the edit sees its payload.
void each_property(std::vector<Box>& meta, const char* type, const std::function<void(Box&)>& edit) {
  heif_fixture::properties(meta, [&](Box& property) {
    if (property.type == type) edit(property);
  });
}
bool is_nclx(const Box& colr) {
  return colr.data.size() >= 11 && std::string(colr.data.begin(), colr.data.begin() + 4) == "nclx";
}
void rename_property(std::vector<Box>& meta, const char* from, const char* to) {
  bool found = false;
  each_property(meta, from, [&](Box& b) {
    b.type = to;
    found = true;
  });
  require(found, std::string("no ") + from + " property");
}
// hvcC payload: [16] chroma_format_idc, [17] luma bit depth - 8. `index` counts
// the hvcC properties in file order: the base image first, then the gain map.
void tamper_hvcc(std::vector<Box>& meta, unsigned index, const std::function<void(Box&)>& edit) {
  unsigned seen = 0;
  bool found = false;
  each_property(meta, "hvcC", [&](Box& b) {
    if (seen++ == index) {
      edit(b);
      found = true;
    }
  });
  require(found, "no matching hvcC");
}
// Zeroes the coded bytes of the first tile of an image, leaving the metadata
// (tmap payload, Exif, XMP) that shares the mdat intact.
Bytes zero_tile(Bytes file, bool gain) {
  const auto parsed = read_heif(file);
  const auto plan = parsed.resolve_gain_map(HeifCanvas::Tiled);
  require(plan.has_value(), "no gain map to corrupt");
  const auto& tile = (gain ? plan->gain : plan->base).tiles.at(0);
  for (const auto& extent : tile.extents) {
    const std::size_t at = extent.offset;
    require(at + extent.length <= file.size(), "tile extent out of range");
    std::fill(file.begin() + at + std::min<std::size_t>(60, extent.length / 2),
              file.begin() + at + extent.length, 0);
  }
  return file;
}
Bytes zero_plain_tile(Bytes file) {
  const auto parsed = read_heif(file);
  const auto plan = parsed.resolve_image(0, HeifCanvas::Tiled);
  for (const auto& extent : plan.tiles.at(0).extents) {
    require(extent.offset + extent.length <= file.size(), "tile extent out of range");
    std::fill(file.begin() + extent.offset + std::min<std::size_t>(60, extent.length / 2),
              file.begin() + extent.offset + extent.length, 0);
  }
  return file;
}
// The tile checks of verify_heif_tiles itself: the decoded picture must match
// the configuration the container declared.
void tile_checks(const Bytes& bytes) {
  const auto file = read_heif(bytes);
  const auto plan = file.resolve_gain_map(HeifCanvas::Tiled);
  require(plan.has_value(), "no plan");
  codec::verify_heif_tiles(file, plan->base);
  codec::verify_heif_tiles(file, plan->gain);
  const auto expect_mismatch = [&](const char* name, const HeifImagePlan& changed) {
    rejects(name, [&] { codec::verify_heif_tiles(file, changed); }, "differs from its configuration");
  };
  auto wider = plan->base;
  wider.tile_width += 16;
  expect_mismatch("tile width", wider);
  auto taller = plan->base;
  taller.tile_height += 16;
  expect_mismatch("tile height", taller);
  // Bit depth and chroma format are decoded from the declared configuration, so
  // a wrong configuration is caught by the structure check (above), not here.
}

// A pair our encoder never writes, built with the HEVC and HEIF writers
// directly: the gain map's size and bit depth are the caller's.
Bytes custom_pair(unsigned base_width, unsigned base_height, unsigned gain_width,
                  unsigned gain_height, bool gain_main10) {
  namespace h = codec::hevc;
  const auto encode_flat = [](unsigned width, unsigned height, bool main10, bool rgb) {
    const auto grid = h::tile_grid(width, height);
    h::EncodeParams params;
    params.main10 = main10;
    params.color = rgb ? h::ColorDescription{12, 13, 1} : h::ColorDescription{2, 2, 1};
    return h::encode(grid.count(), [&](std::size_t index, h::YuvTile& tile) {
      if (rgb)
        h::rgb_tile(grid, index, [](auto, auto, auto n, float* v) { std::fill_n(v, n * 3, .5F); },
                    1, true, tile);
      else
        h::luma_tile(grid, index, [](auto, auto, auto n, float* v) { std::fill_n(v, n, .5F); }, tile);
    }, params);
  };
  const auto base = encode_flat(base_width, base_height, false, true);
  const auto gain = encode_flat(gain_width, gain_height, gain_main10, false);
  const auto icc = codec::display_p3_profile();
  HeifEncodedImage b{base, base_width, base_height, {}, std::nullopt, icc};
  HeifEncodedImage g{gain, gain_width, gain_height, {2, 2, 1, true}, std::nullopt, {}};
  HeifWriteOptions options;
  options.gain_metadata = GainMapMetadata{};
  return write_heif(b, &g, options);
}

void adaptive_cases(int depth) {
  const auto bytes = encode_adaptive_heic(make_gain(96, 64), {}, 90, depth);
  const std::string label = "adaptive" + std::to_string(depth);
  verify_heic_decodable(bytes);
  verify_heic_decodable(bytes, HdrEncoding::Adaptive);
  const auto verify = [](const Bytes& b) { return [b] { verify_heic_decodable(b); }; };
  {  // The ftyp compatible brand list loses tmap.
    auto broken = bytes;
    replace_text(broken, "tmap", "tmax");
    rejects("missing tmap brand", verify(broken), "tmap");
  }
  {
    auto broken = with_boxes(bytes, [](auto& meta) {
      heif_fixture::properties(meta, [](Box& p) {
        if (p.type == "auxC") replace_text(p.data, "urn:iso:std:iso:ts:21496:-1", "urn:iso:std:iso:ts:21496:-2");
      });
    });
    rejects("wrong ISO auxiliary type", verify(broken), "auxiliary type");
  }
  {
    auto broken = with_boxes(bytes, [](auto& meta) {
      for (auto& b : meta)
        if (b.type == "iref")
          heif_fixture::children(b, 4, [](auto& refs) {
            for (auto& r : refs)
              if (r.type == "auxl") r.type = "auxx";
          });
    });
    rejects("missing auxl", verify(broken), "auxl");
  }
  {
    auto broken = with_boxes(bytes, [](auto& meta) {
      for (auto& b : meta)
        if (b.type == "grpl") b.type = "grpx";
    });
    rejects("missing altr group", verify(broken), "altr");
  }
  {  // Matrix 9 is BT.2020: not the 2/2/1/full the gain map must carry.
    auto broken = with_boxes(bytes, [](auto& meta) {
      bool found = false;
      each_property(meta, "colr", [&](Box& c) {
        if (is_nclx(c) && heif_fixture::get(c.data, 4, 2) == 2) {
          heif_fixture::put(c.data, 8, 9, 2);
          found = true;
        }
      });
      require(found, "no gain nclx");
    });
    rejects("gain nclx matrix", verify(broken), "Gain Map");
  }
  {
    auto broken = with_boxes(bytes, [](auto& meta) {
      each_property(meta, "colr", [](Box& c) {
        if (is_nclx(c) && heif_fixture::get(c.data, 4, 2) == 2) c.data[10] = 0;  // limited range
      });
    });
    rejects("gain nclx limited range", verify(broken), "Gain Map");
  }
  {  // With an ICC profile present, the base's nclx still has to describe an SDR picture.
    const auto bad_base = [&](const char* name, const std::function<void(Box&)>& edit) {
      auto broken = with_boxes(bytes, [&](auto& meta) {
        bool found = false;
        each_property(meta, "colr", [&](Box& c) {
          if (is_nclx(c) && heif_fixture::get(c.data, 4, 2) != 2) {
            edit(c);
            found = true;
          }
        });
        require(found, "no base nclx");
      });
      rejects(name, verify(broken), "SDR base");
    };
    bad_base("base nclx PQ transfer", [](Box& c) { heif_fixture::put(c.data, 6, 16, 2); });
    bad_base("base nclx BT.2020 primaries", [](Box& c) { heif_fixture::put(c.data, 4, 9, 2); });
    bad_base("base nclx BT.2020 matrix", [](Box& c) { heif_fixture::put(c.data, 8, 9, 2); });
    bad_base("base nclx limited range", [](Box& c) { c.data[10] = 0; });
  }
  {  // The gain map may not be larger than its base, nor anything but 8-bit.
    verify_heic_decodable(custom_pair(64, 64, 32, 32, false));
    // The writer refuses a larger gain map, so shrink a valid pair's base: the
    // base grid's ispe and its grid descriptor both say 32x32 while the gain map
    // stays 64x64.
    auto smaller_base = custom_pair(128, 128, 64, 64, false);
    {
      const auto parsed = read_heif(smaller_base);
      const auto& grid = parsed.item(parsed.resolve_image().item_id);
      require(grid.type == "grid" && grid.extents.size() == 1 && grid.extents[0].length == 8,
              "base grid descriptor not found");
      const auto at = grid.extents[0].offset;  // version, flags, rows-1, columns-1, width, height
      require(smaller_base[at + 1] == 0, "grid descriptor uses 32-bit sizes");
      smaller_base[at + 4] = smaller_base[at + 6] = 0;
      smaller_base[at + 5] = smaller_base[at + 7] = 32;
    }
    smaller_base = with_boxes(smaller_base, [](auto& meta) {
      each_property(meta, "ispe", [](Box& b) {
        if (heif_fixture::get(b.data, 4, 4) == 128 && heif_fixture::get(b.data, 8, 4) == 128) {
          heif_fixture::put(b.data, 4, 32, 4);
          heif_fixture::put(b.data, 8, 32, 4);
        }
      });
    });
    // The reader refuses it before the verifier's own size check is reached.
    rejects("gain map larger than base", [&] { verify_heic_decodable(smaller_base); },
            "exceeds base dimensions");
    rejects("gain map 10-bit", [] { verify_heic_decodable(custom_pair(64, 64, 32, 32, true)); },
            "invalid dimensions or depth");
  }
  {  // The gain map is coded 4:2:0; the configuration now claims monochrome.
    auto broken = with_boxes(bytes, [](auto& meta) {
      tamper_hvcc(meta, 1, [](Box& b) { b.data[16] = 0xFC; });
    });
    rejects("gain chroma format", verify(broken), "HEVC");
  }
  {  // Base: the stream is 8 (or 10) bit, the configuration says the other.
    auto broken = with_boxes(bytes, [&](auto& meta) {
      tamper_hvcc(meta, 0, [&](Box& b) { b.data[17] = 0xF8 | (depth == 8 ? 2 : 0); });
    });
    rejects("base bit depth", verify(broken), "depths differ");
  }
  {  // The picture is larger than the decoded stream.
    auto broken = with_boxes(bytes, [](auto& meta) {
      heif_fixture::properties(meta, [](Box& p) {
        if (p.type == "ispe") heif_fixture::put(p.data, 4, 4000, 4);
      });
    });
    rejects("oversized ispe", verify(broken), "ispe");
  }
  rejects("zeroed base tile", verify(zero_tile(bytes, false)), "HEVC");
  rejects("zeroed gain tile", verify(zero_tile(bytes, true)), "HEVC");
  tile_checks(bytes);
  {  // A broken file at its path takes the same route as the bytes.
    const auto path = test::temporary_directory() / ("heic-verify-" + label + ".heic");
    auto broken = bytes;
    replace_text(broken, "tmap", "tmax");
    write_binary_file_atomic(path, broken, true);
    rejects("path overload", [&] { verify_heic_decodable(path); }, nullptr);
    std::filesystem::remove(path);
  }
}

void bt2100_cases(HdrEncoding encoding) {
  const auto pq = encoding == HdrEncoding::Pq;
  const auto bytes = encode_hdr_heic(test::decoded_pair(make_gain(96, 64)), {}, 90, encoding);
  verify_heic_decodable(bytes, encoding);
  const auto path = test::temporary_directory() / (pq ? "heic-verify-pq.heic" : "heic-verify-hlg.heic");
  write_binary_file_atomic(path, bytes, true);
  verify_heic_decodable(path);  // the file's own transfer picks PQ or HLG
  std::filesystem::remove(path);
  const auto verify = [&](const Bytes& b) { return [b, encoding] { verify_heic_decodable(b, encoding); }; };
  rejects("other transfer", [&] { verify_heic_decodable(bytes, pq ? HdrEncoding::Hlg : HdrEncoding::Pq); },
          "nclx");
  const auto edit_nclx = [&](const std::function<void(Box&)>& edit) {
    return with_boxes(bytes, [&](auto& meta) {
      each_property(meta, "colr", [&](Box& c) {
        if (is_nclx(c)) edit(c);
      });
    });
  };
  rejects("sdr transfer", verify(edit_nclx([](Box& c) { heif_fixture::put(c.data, 6, 1, 2); })), "nclx");
  rejects("bt709 matrix", verify(edit_nclx([](Box& c) { heif_fixture::put(c.data, 8, 1, 2); })), "nclx");
  rejects("limited range", verify(edit_nclx([](Box& c) { c.data[10] = 0; })), "nclx");
  rejects("bt709 primaries", verify(edit_nclx([](Box& c) { heif_fixture::put(c.data, 4, 1, 2); })), "nclx");
  {  // SDR transfer is neither PQ nor HLG for the file-level dispatcher.
    const auto path = test::temporary_directory() / "heic-verify-sdr-transfer.heic";
    write_binary_file_atomic(
        path, edit_nclx([](Box& c) { heif_fixture::put(c.data, 6, 1, 2); }), true);
    rejects("dispatch", [&] { verify_heic_decodable(path); }, "neither Adaptive HDR, PQ, nor HLG");
    std::filesystem::remove(path);
  }
  rejects("missing clli", verify(with_boxes(bytes, [](auto& meta) { rename_property(meta, "clli", "clix"); })),
          "content-light");
  rejects("8-bit configuration",
          verify(with_boxes(bytes, [](auto& meta) { tamper_hvcc(meta, 0, [](Box& b) { b.data[17] = 0xF8; }); })),
          nullptr);
  rejects("monochrome configuration",
          verify(with_boxes(bytes, [](auto& meta) { tamper_hvcc(meta, 0, [](Box& b) { b.data[16] = 0xFC; }); })),
          nullptr);
  rejects("zeroed tile", verify(zero_plain_tile(bytes)), "HEVC");
  {  // An Adaptive file is not a BT.2100 one.
    const auto adaptive = encode_adaptive_heic(make_gain(96, 64), {}, 90, 10);
    rejects("adaptive as BT.2100", [&] { verify_heic_decodable(adaptive, encoding); },
            "semantic structure verification");
  }
}

unsigned tiff_dimension(const Bytes& tiff, std::size_t entry) {
  // Classic little-endian TIFF: the IFD at 8, entries of 12 bytes, value at +8.
  const auto at = 10 + entry * 12 + 8;
  return unsigned(tiff[at]) | unsigned(tiff[at + 1]) << 8 | unsigned(tiff[at + 2]) << 16 |
         unsigned(tiff[at + 3]) << 24;
}
// 12000 is past the raster edge limit, where input decoding would halve it.
void diagnostics_see_the_whole_canvas() {
  const auto root = test::temporary_directory() / "heic-verify-wide";
  std::filesystem::create_directories(root);
  const auto file = root / "wide.heic";
  write_binary_file_atomic(file, encode_adaptive_heic(make_gain(12000, 256), {}, 80, 8), true);
  verify_heic_decodable(file);
  const auto tiff = root / "wide.tiff";
  reconstruct_heic_to_tiff(file, tiff);
  const auto bytes = read_binary_file(tiff);
  require(tiff_dimension(bytes, 0) == 12000 && tiff_dimension(bytes, 1) == 256,
          "--reconstruct changed the canvas size");
  const auto curve = compare_gain_map_heic_curve(file, file, {1.F});
  require(curve.points.size() == 1 && curve.points[0].total_pixels == 12000ULL * 256 &&
              curve.points[0].mae_linear_p3 == 0,
          "display-curve did not compare every pixel");
  {  // A budget that cannot hold the planes stops the command; nothing is reduced.
    ExecutionScope tight({0, 12000ULL * 256 * 20});
    rejects("reconstruct over budget", [&] { reconstruct_heic_to_tiff(file, root / "tight.tiff"); },
            "do not work on a reduced copy");
    rejects("display-curve over budget", [&] { compare_gain_map_heic_curve(file, file, {1.F}); },
            "do not work on a reduced copy");
    require(!std::filesystem::exists(root / "tight.tiff"), "a rejected reconstruct left a file");
  }
  {  // Display-curve holds both files at once: one fits 40 B/px, two (52 in all) do not.
    ExecutionScope between({0, 12000ULL * 256 * 45});
    reconstruct_heic_to_tiff(file, root / "between.tiff");
    rejects("display-curve with two files", [&] { compare_gain_map_heic_curve(file, file, {1.F}); },
            "do not work on a reduced copy");
  }
  {
    ExecutionScope enough({0, 12000ULL * 256 * 64});
    reconstruct_heic_to_tiff(file, root / "enough.tiff");
    (void)compare_gain_map_heic_curve(file, file, {1.F});
  }
  std::filesystem::remove_all(root);
}
}  // namespace
int main() try {
  adaptive_cases(8);
  adaptive_cases(10);
  bt2100_cases(HdrEncoding::Pq);
  bt2100_cases(HdrEncoding::Hlg);
  diagnostics_see_the_whole_canvas();
  std::cout << "heic_verify_test passed\n";
} catch (const std::exception& error) {
  std::cerr << "heic_verify_test: " << error.what() << '\n';
  return 1;
}

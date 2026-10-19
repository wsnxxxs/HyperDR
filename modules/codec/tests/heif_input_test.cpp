#include <iostream>

#include "../../../tests/support/temp_directory.hpp"
#include "heif_fixture_edit.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/orientation.hpp"
#include "internal/icc_profiles.hpp"
using namespace hyperdr;
namespace {
void require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
DecodedImage decode(const std::vector<std::uint8_t>& bytes, RawDecodeOptions options = {}) {
  auto p = test::temporary_directory() / "input-reader.heic";
  write_binary_file_atomic(p, bytes, true);
  return decode_image(p, options);
}
std::vector<std::uint8_t> properties(std::vector<std::uint8_t> bytes,
                                     std::vector<heif_fixture::Box> extra) {
  const auto primary = read_heif(bytes).primary_item_id;
  return heif_fixture::edit(bytes, [&](auto& meta) {
    for (auto& b : meta)
      if (b.type == "iprp")
        heif_fixture::children(b, 0, [&](auto& iprp) {
          unsigned count = 0;
          for (auto& c : iprp)
            if (c.type == "ipco")
              heif_fixture::children(c, 0, [&](auto& props) {
                count = props.size();
                props.insert(props.end(), extra.begin(), extra.end());
              });
          for (auto& c : iprp)
            if (c.type == "ipma") {
              require(c.data[0] == 0 && !(c.data[3] & 1), "unexpected fixture ipma");
              for (unsigned i = 0, p = 8; i < heif_fixture::get(c.data, 4, 4); ++i) {
                auto id = heif_fixture::get(c.data, p, 2);
                auto n = c.data[p + 2];
                if (id == primary) {
                  for (unsigned k = 0; k < extra.size(); ++k)
                    c.data.insert(c.data.begin() + p + 3 + n + k, 128 + count + k + 1);
                  c.data[p + 2] += extra.size();
                  break;
                }
                p += 3 + n;
              }
            }
        });
  });
}
void run() {
  namespace h = codec::hevc;
  h::EncodeParams params;
  params.quality = 100;
  params.color = {12, 13, 1};
  auto stream = h::encode(
      4,
      [](std::size_t i, h::YuvTile& tile) {
        h::rgb_tile(
            h::tile_grid(1024, 1024), i,
            [&](auto, auto, auto n, float* row) {
              for (unsigned x = 0; x < n; ++x) {
                row[x * 3] = .1F + .15F * i;
                row[x * 3 + 1] = .3F;
                row[x * 3 + 2] = .5F;
              }
            },
            1, false, tile);
      },
      params);
  HeifEncodedImage image{stream, 700, 600, {12, 13, 1, true}, std::nullopt, {}};
  const auto bytes = write_heif(image);
  const auto base = decode(bytes);
  require(base.linear_p3.width == 700 && base.linear_p3.height == 600 &&
              base.decode.sensor_width == 700,
          "grid input geometry changed");
  const auto transformed = properties(bytes, {{"imir", {0}}, {"irot", {1}}});
  auto expected = apply_exif_orientation(apply_exif_orientation(base.linear_p3, 2), 8);
  const auto rotated = decode(transformed);
  require(rotated.linear_p3.width == 600 && rotated.linear_p3.height == 700 &&
              rotated.linear_p3.pixels == expected.pixels,
          "ordered mirror/rotate did not preserve grid pixels");
  RawDecodeOptions preview;
  preview.preview_max_edge = 128;
  const auto small = decode(bytes, preview);
  require(small.linear_p3.width == 175 && small.linear_p3.height == 150 &&
              small.decode.target_width == 700 && small.decode.decoded_width == 175 &&
              !small.decode.resolution_reduced,
          "grid preview geometry changed");
  const auto identity = heif_fixture::edit(bytes, [](auto& meta) {
    heif_fixture::properties(meta, [](auto& prop) {
      if (prop.type == "ispe") {
        heif_fixture::put(prop.data, 4, 512, 4);
        heif_fixture::put(prop.data, 8, 512, 4);
      }
    });
    for (auto& b : meta) {
      if (b.type == "iinf")
        heif_fixture::children(b, 8, [](auto& items) {
          for (auto& i : items)
            if (i.type == "infe" && heif_fixture::get(i.data, 4, 2) == 1)
              std::copy_n("iden", 4, i.data.begin() + 8);
        });
      if (b.type == "iref")
        heif_fixture::children(b, 4, [](auto& refs) {
          for (auto& r : refs)
            if (r.type == "dimg" && heif_fixture::get(r.data, 0, 2) == 1) {
              heif_fixture::put(r.data, 2, 1, 2);
              r.data.resize(6);
            }
        });
    }
  });
  const auto iden = decode(identity);
  require(iden.linear_p3.width == 512 && iden.linear_p3.height == 512 &&
              iden.linear_p3.at(50, 50, 0) == base.linear_p3.at(50, 50, 0),
          "identity did not select its coded input");
  const auto icc = codec::display_p3_profile();
  auto mixed = image;
  mixed.display_p3_icc = icc;
  const auto with_color = [&](unsigned transfer, bool light) {
    auto encoded = mixed;
    if (light) encoded.light = HeifContentLight{1200, 500};
    return heif_fixture::edit(write_heif(encoded), [&](auto& meta) {
      heif_fixture::properties(meta, [&](auto& prop) {
        if (prop.type == "colr" &&
            std::string(prop.data.begin(), prop.data.begin() + 4) == "nclx") {
          heif_fixture::put(prop.data, 4, 9, 2);
          heif_fixture::put(prop.data, 6, transfer, 2);
          heif_fixture::put(prop.data, 8, 9, 2);
        }
      });
    });
  };
  require(decode(with_color(13, false)).source_color.source == "icc",
          "SDR ICC did not precede nclx");
  const auto pq = decode(with_color(16, true));
  require(pq.source_color.source == "cicp" && pq.source_color.transfer == "PQ" &&
              pq.content_peak_nits == 1200,
          "PQ nclx did not precede SDR ICC or lost clli");
  const auto unsupported = heif_fixture::edit(bytes, [](auto& meta) {
    heif_fixture::properties(meta, [](auto& prop) {
      if (prop.type == "hvcC") prop.type = "zzzz";
    });
  });
  bool refused = false;
  try {
    (void)decode(unsupported);
  } catch (const UnsupportedFormat& e) {
    refused = e.detail_json() == "{\"container\":\"heif\",\"feature\":\"essential_property\"}";
  }
  require(refused, "input did not preserve structured unsupported-format detail");
}
}  // namespace
int main() try {
  run();
  return 0;
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}

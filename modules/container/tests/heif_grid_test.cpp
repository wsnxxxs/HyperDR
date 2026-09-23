#include "hyperdr/container/heif_grid.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"

#include "internal/items.hpp"

#include <stdexcept>
#include <string_view>

namespace {

using hyperdr::container::Bytes;
using hyperdr::container::children;
using hyperdr::container::make_box;
using hyperdr::container::parse_iinf;
using hyperdr::container::parse_pitm;
using hyperdr::container::put16;
using hyperdr::container::put32;

void require(bool okay, const char* message) {
  if (!okay) throw std::runtime_error(message);
}

void append(Bytes& to, const Bytes& from) {
  to.insert(to.end(), from.begin(), from.end());
}

Bytes leaf(std::uint8_t marker, std::string_view brand = "heic") {
  Bytes ftyp_payload(brand.begin(), brand.end());
  ftyp_payload.insert(ftyp_payload.end(), {0, 0, 0, 0, 'm', 'i', 'f', '1'});
  ftyp_payload.insert(ftyp_payload.end(), brand.begin(), brand.end());
  const auto ftyp = make_box("ftyp", ftyp_payload);
  const auto hdlr = make_box("hdlr", Bytes{0, 0, 0, 0, 0, 0, 0, 0,
                                            'p', 'i', 'c', 't', 0, 0, 0, 0,
                                            0, 0, 0, 0, 0, 0, 0, 0, 0});
  Bytes pitm_payload{0, 0, 0, 0};
  put16(pitm_payload, 1);
  const auto pitm = make_box("pitm", pitm_payload);
  Bytes infe_payload{2, 0, 0, 0};
  put16(infe_payload, 1);
  put16(infe_payload, 0);
  infe_payload.insert(infe_payload.end(), {'h', 'v', 'c', '1', 'I', 'm', 'a', 'g', 'e', 0});
  Bytes iinf_payload{1, 0, 0, 0};
  put32(iinf_payload, 1);
  append(iinf_payload, make_box("infe", infe_payload));
  const auto iinf = make_box("iinf", iinf_payload);

  const auto hvcc = make_box("hvcC", Bytes{marker, 1, 2, 3});
  Bytes ispe_payload{0, 0, 0, 0};
  put32(ispe_payload, 2);
  put32(ispe_payload, 2);
  const auto ispe = make_box("ispe", ispe_payload);
  const auto pixi = make_box("pixi", Bytes{0, 0, 0, 0, 3, 8, 8, 8});
  const auto colr = make_box("colr", Bytes{'n', 'c', 'l', 'x', 0, 1});
  Bytes ipco_payload;
  for (const auto& property : {hvcc, ispe, pixi, colr}) append(ipco_payload, property);
  const auto ipco = make_box("ipco", ipco_payload);
  Bytes ipma_payload{0, 0, 0, 0};
  put32(ipma_payload, 1);
  put16(ipma_payload, 1);
  ipma_payload.insert(ipma_payload.end(), {4, 0x81, 2, 3, 4});
  Bytes iprp_payload;
  append(iprp_payload, ipco);
  append(iprp_payload, make_box("ipma", ipma_payload));
  const auto iprp = make_box("iprp", iprp_payload);

  const auto make_meta = [&](std::uint32_t offset) {
    Bytes iloc_payload{1, 0, 0, 0, 0x44, 0};
    put16(iloc_payload, 1);
    put16(iloc_payload, 1);
    put16(iloc_payload, 0);
    put16(iloc_payload, 0);
    put16(iloc_payload, 1);
    put32(iloc_payload, offset);
    put32(iloc_payload, 4);
    Bytes meta_payload{0, 0, 0, 0};
    for (const auto& box : {hdlr, pitm, iinf, make_box("iloc", iloc_payload), iprp}) {
      append(meta_payload, box);
    }
    return make_box("meta", meta_payload);
  };
  auto meta = make_meta(0);
  meta = make_meta(static_cast<std::uint32_t>(ftyp.size() + meta.size() + 8));
  const auto mdat = make_box("mdat", Bytes{marker, 0, 0, 1});
  Bytes file;
  for (const auto& box : {ftyp, meta, mdat}) append(file, box);
  return file;
}

void test_grid_and_single_image() {
  hyperdr::EncodedHeifGrid gain{4, 2, 2, 1, {leaf(0x11), leaf(0x22)}};
  hyperdr::EncodedHeifGrid base{2, 2, 1, 1, {leaf(0x33, "heix")}};
  const auto result = hyperdr::assemble_heif_grids(
      {gain, base}, 1, {'I', 'I', 42, 0}, "<xmp/>");
  const auto top = children(result, 0, result.size());
  require(top.size() == 3 && top[0].type == "ftyp" && top[1].type == "meta" &&
              top[2].type == "mdat", "assembled HEIF top-level boxes are wrong");
  require(std::string_view(reinterpret_cast<const char*>(result.data() + 8), 4) == "heix",
          "primary image's Main10 brand was not retained as the major brand");
  bool heic_brand = false, heix_brand = false;
  for (std::size_t p = 16; p < top[0].size; p += 4) {
    const auto brand = std::string_view(reinterpret_cast<const char*>(result.data() + p), 4);
    heic_brand |= brand == "heic";
    heix_brand |= brand == "heix";
  }
  require(heic_brand && heix_brand, "tile compatible brands were not merged");
  const auto meta = std::span<const std::uint8_t>(result).subspan(top[1].offset, top[1].size);
  const auto kids = children(meta, 12, meta.size());
  Bytes iinf, pitm, iref;
  for (const auto& box : kids) {
    if (box.type == "iinf") iinf = hyperdr::container::slice(meta, box);
    if (box.type == "pitm") pitm = hyperdr::container::slice(meta, box);
    if (box.type == "iref") iref = hyperdr::container::slice(meta, box);
  }
  const auto items = parse_iinf(iinf);
  require(items.size() == 6 && items[0].type == "grid" &&
              items[1].type == "hvc1" && items[2].type == "hvc1" &&
              items[3].type == "hvc1" && items[4].type == "Exif" &&
              items[5].type == "mime", "grid items or metadata items are wrong");
  require((items[1].infe[11] & 1) && (items[2].infe[11] & 1),
          "grid tiles are not hidden");
  require(parse_pitm(pitm) == items[3].id, "wrong primary logical image");
  bool dimg = false, cdsc = false;
  for (const auto& box : children(iref, 12, iref.size())) {
    if (box.type == "dimg") dimg = true;
    if (box.type == "cdsc") cdsc = true;
  }
  require(dimg && cdsc, "grid or metadata references are missing");
  const auto tmap = hyperdr::add_tmap_to_two_image_heif(
      result, hyperdr::serialize_tmap_payload(hyperdr::GainMapMetadata{}));
  const auto references = hyperdr::find_tmap_references(tmap);
  require(references.gain_id == items[0].id && references.base_id == items[3].id,
          "tmap did not connect the assembled gain and base images");
}

void test_invalid_tile_count() {
  try {
    (void)hyperdr::assemble_heif_grids({{4, 2, 2, 1, {leaf(1)}}}, 0, {}, "");
  } catch (const std::invalid_argument&) {
    return;
  }
  throw std::runtime_error("incorrect tile count was accepted");
}

}  // namespace

int main() {
  test_grid_and_single_image();
  test_invalid_tile_count();
}

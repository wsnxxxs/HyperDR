#pragma once
// Synthetic alpha containers only: VT owns the samples, and idat offsets are
// written from known payload positions. No external HEIF writer or decoder.
#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "internal/boxes.hpp"
namespace heif_test {
inline std::vector<std::uint8_t> rgba(bool premultiplied, bool adaptive = false,
                                      unsigned size = 32) {
  using namespace hyperdr;
  using namespace hyperdr::container;
  namespace h = hyperdr::codec::hevc;
  auto encode = [&](unsigned kind) {
    h::EncodeParams params;
    params.quality = 100;
    params.color = {12, 13, 1};
    return h::encode(
        1,
        [&](std::size_t, h::YuvTile& tile) {
          for (unsigned y = 0; y < 512; ++y)
            for (unsigned x = 0; x < 512; ++x) {
              constexpr unsigned char a[]{0, 128, 255, 128};
              auto alpha = a[std::min(x, size - 1) / (size / 4)];
              tile.luma[y * 512 + x] = kind == 1                ? alpha
                                       : kind == 2              ? 255
                                       : premultiplied && alpha ? alpha
                                                                : 255;
            }
          std::fill(tile.chroma.begin(), tile.chroma.end(), 128);
        },
        params);
  };
  auto base = encode(0), alpha = encode(1), gain = adaptive ? encode(2) : h::EncodedSequence{};
  auto config = [](const auto& s) { return make_hevc_configuration(s.vps, s.sps, s.pps).record; };
  auto grid = [&] {
    Bytes b{0, 0, 0, 0};
    put16(b, size);
    put16(b, size);
    return b;
  };
  std::vector<Bytes> payloads{grid(), base.samples[0], grid(), alpha.samples[0]};
  if (adaptive) {
    payloads.push_back(grid());
    payloads.push_back(gain.samples[0]);
    GainMapMetadata m;
    m.gain_max = {1, 1};
    m.alternate_headroom = {1, 1};
    m.base_offset = {1, 4};
    m.alternate_offset = {1, 8};
    payloads.push_back(serialize_tmap_payload(m));
  }
  const unsigned count = payloads.size();
  Bytes items{0, 0, 0, 0};
  put16(items, count);
  for (unsigned id = 1; id <= count; ++id) {
    Bytes p{2, 0, 0, static_cast<std::uint8_t>(id == 2 || id == 4 || id == 6)};
    put16(p, id);
    put16(p, 0);
    auto type = id == 7 ? "tmap" : id & 1 ? "grid" : "hvc1";
    p.insert(p.end(), type, type + 4);
    p.push_back(0);
    auto b = make_box("infe", p);
    items.insert(items.end(), b.begin(), b.end());
  }
  auto ispe = [](unsigned w) {
    Bytes p(4);
    put32(p, w);
    put32(p, w);
    return make_box("ispe", p);
  };
  auto aux = [](const char* text) {
    Bytes p(4);
    while (*text) p.push_back(*text++);
    p.push_back(0);
    return make_box("auxC", p);
  };
  Bytes colr{'n', 'c', 'l', 'x'};
  put16(colr, 12);
  put16(colr, 13);
  put16(colr, 1);
  colr.push_back(128);
  std::vector<Bytes> props{ispe(size),
                           ispe(512),
                           make_box("colr", colr),
                           make_box("hvcC", config(base)),
                           make_box("hvcC", config(alpha)),
                           make_box("hvcC", adaptive ? config(gain) : config(base)),
                           aux("urn:mpeg:hevc:2015:auxid:1"),
                           aux("urn:iso:std:iso:ts:21496:-1")};
  Bytes ipco;
  for (auto& p : props) ipco.insert(ipco.end(), p.begin(), p.end());
  std::vector<Bytes> assoc{{1, 3}, {2, 132}, {1, 7}, {2, 133}, {1, 3, 8}, {2, 134}, {}};
  Bytes ipma{0, 0, 0, 0};
  put32(ipma, count);
  for (unsigned id = 1; id <= count; ++id) {
    put16(ipma, id);
    ipma.push_back(assoc[id - 1].size());
    ipma.insert(ipma.end(), assoc[id - 1].begin(), assoc[id - 1].end());
  }
  Bytes iprp = make_box("ipco", ipco);
  auto append = [](Bytes& out, const Bytes& in) { out.insert(out.end(), in.begin(), in.end()); };
  append(iprp, make_box("ipma", ipma));
  Bytes refs(4);
  auto ref = [&](const char* type, unsigned from, std::initializer_list<unsigned> to) {
    Bytes p;
    put16(p, from);
    put16(p, to.size());
    for (auto id : to) put16(p, id);
    append(refs, make_box(type, p));
  };
  ref("dimg", 1, {2});
  ref("dimg", 3, {4});
  ref("auxl", 3, {1});
  if (premultiplied) ref("prem", 1, {3});
  if (adaptive) {
    ref("dimg", 5, {6});
    ref("dimg", 7, {1, 5});
    ref("auxl", 5, {1});
  }
  Bytes iloc{1, 0, 0, 0, 0x44, 0};
  put16(iloc, count);
  Bytes idat;
  for (unsigned id = 1; id <= count; ++id) {
    put16(iloc, id);
    put16(iloc, 1);
    put16(iloc, 0);
    put16(iloc, 1);
    put32(iloc, idat.size());
    put32(iloc, payloads[id - 1].size());
    append(idat, payloads[id - 1]);
  }
  Bytes meta(4);
  append(meta, make_box("hdlr", Bytes{0, 0, 0, 0, 0, 0, 0, 0, 'p', 'i', 'c', 't', 0,
                                      0, 0, 0, 0, 0, 0, 0, 0, 0,   0,   0,   0}));
  append(meta, make_box("pitm", Bytes{0, 0, 0, 0, 0, 1}));
  append(meta, make_box("iinf", items));
  append(meta, make_box("iloc", iloc));
  append(meta, make_box("iprp", iprp));
  append(meta, make_box("iref", refs));
  if (adaptive) {
    Bytes altr(4);
    put32(altr, 8);
    put32(altr, 2);
    put32(altr, 7);
    put32(altr, 1);
    append(meta, make_box("grpl", make_box("altr", altr)));
  }
  append(meta, make_box("idat", idat));
  Bytes ftyp{'h', 'e', 'i', 'c', 0, 0, 0, 0, 'm', 'i', 'f', '1', 'h', 'e', 'i', 'c'};
  if (adaptive) ftyp.insert(ftyp.end(), {'t', 'm', 'a', 'p'});
  auto out = make_box("ftyp", ftyp);
  append(out, make_box("meta", meta));
  return out;
}
}  // namespace heif_test

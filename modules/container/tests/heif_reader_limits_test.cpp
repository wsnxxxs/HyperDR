#include <exception>
#include <pthread.h>

#include <iostream>

#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/raster_budget.hpp"
#include "internal/bmff.hpp"
#include "internal/boxes.hpp"
using namespace hyperdr;
using namespace hyperdr::container;
namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
template <class F>
void rejects(F f) {
  try {
    f();
  } catch (const HeifReadError&) {
    return;
  }
  throw std::runtime_error("HEIF limit overflow accepted");
}
void append(Bytes& a, const Bytes& b) { a.insert(a.end(), b.begin(), b.end()); }
Bytes fixture(std::size_t items = 1, std::size_t props = 3, std::size_t associations = 3,
              std::size_t icc = 0, std::size_t extent_count = 1) {
  auto seed = read_binary_file(std::filesystem::path(HYPERDR_MALFORMED_FIXTURES) / "valid.heic");
  auto parsed = read_heif(seed);
  Bytes out = make_box("ftyp", Bytes{'h', 'e', 'i', 'c', 0, 0, 0, 0, 'm', 'i', 'f', '1'});
  Bytes meta(4);
  append(meta, make_box("hdlr", Bytes{0, 0, 0, 0, 0, 0, 0, 0, 'p', 'i', 'c', 't', 0,
                                      0, 0, 0, 0, 0, 0, 0, 0, 0,   0,   0,   0}));
  append(meta, make_box("pitm", Bytes{0, 0, 0, 0, 0, 1}));
  Bytes iinf{1, 0, 0, 0};
  put32(iinf, items);
  for (std::size_t id = 1; id <= items; ++id) {
    Bytes infe{3, 0, 0, 0};
    put32(infe, id);
    put16(infe, 0);
    infe.insert(infe.end(), {'h', 'v', 'c', '1', 0});
    append(iinf, make_box("infe", infe));
  }
  append(meta, make_box("iinf", iinf));
  auto sample = parsed.item_bytes(1);
  Bytes iloc{1, 0, 0, 0, 0x44, 0};
  const auto entries = extent_count > 65535 ? 2U : 1U;
  put16(iloc, entries);
  std::size_t remaining = extent_count;
  for (unsigned id = 1; id <= entries; ++id) {
    put16(iloc, id);
    put16(iloc, 1);
    put16(iloc, 0);
    const auto count = std::min<std::size_t>(remaining, 65535);
    put16(iloc, count);
    for (std::size_t e = 0; e < count; ++e) {
      put32(iloc, 0);
      put32(iloc, extent_count == 1 ? sample.size() : 0);
    }
    remaining -= count;
  }
  append(meta, make_box("iloc", iloc));
  Bytes ipco;
  for (std::size_t i = 0; i < props; ++i) {
    if (i < 3)
      append(ipco, make_box(parsed.properties[i].type, {parsed.properties[i].payload.begin(),
                                                        parsed.properties[i].payload.end()}));
    else
      append(ipco, make_box("zzzz", {}));
  }
  if (icc) {
    Bytes p{'p', 'r', 'o', 'f'};
    p.resize(4 + icc);
    append(ipco, make_box("colr", p));
  }
  Bytes ipma{0, 0, 0, 0};
  put32(ipma, 1);
  put16(ipma, 1);
  ipma.push_back(associations);
  for (std::size_t i = 0; i < associations; ++i)
    ipma.push_back(static_cast<std::uint8_t>(i < 3 ? i + 1 : 3));
  Bytes iprp = make_box("ipco", ipco);
  append(iprp, make_box("ipma", ipma));
  append(meta, make_box("iprp", iprp));
  append(meta, make_box("idat", sample));
  append(out, make_box("meta", meta));
  return out;
}
void run() {
  auto bytes = fixture();
  auto f = read_heif(bytes);
  require(f.resolve_image().width == 512, "idat construction failed");
  auto n = f.boxes.size();
  auto many = bytes;
  for (std::size_t i = n; i < heif_limits::boxes; ++i) append(many, make_box("free", {}));
  require(read_heif(many).boxes.size() == heif_limits::boxes, "box boundary rejected");
  require(inspect_heif(many).structurally_valid,"inspect box boundary rejected");
  append(many, make_box("free", {}));
  rejects([&] { (void)read_heif(many); });
  require(!inspect_heif(many).structurally_valid,"inspect box overflow accepted");
  for (unsigned depth : {8U, 9U}) {
    Bytes nested;
    for (unsigned i = 0; i <= depth; ++i) nested = make_box("ipco", nested);
    auto b = bytes;
    append(b, nested);
    if (depth == 8)
      (void)read_heif(b);
    else
      rejects([&] { (void)read_heif(b); });
  }
  for (auto count : {heif_limits::items, heif_limits::items + 1}) {
    auto b = fixture(count);
    if (count == heif_limits::items)
      require(read_heif(b).items.size() == count, "item boundary rejected");
    else
      rejects([&] { (void)read_heif(b); });
  }
  for (auto count : {heif_limits::properties, heif_limits::properties + 1}) {
    auto b = fixture(1, count);
    if (count == heif_limits::properties)
      require(read_heif(b).properties.size() == count, "property boundary rejected");
    else
      rejects([&] { (void)read_heif(b); });
  }
  for (auto count : {heif_limits::extents, heif_limits::extents + 1}) {
    auto b = fixture(2, 3, 3, 0, count);
    if (count == heif_limits::extents)
      (void)read_heif(b);
    else
      rejects([&] { (void)read_heif(b); });
  }
  require(checked_grid_tile_count(256, 256) == 65536, "grid tile boundary rejected");
  rejects([] { (void)checked_grid_tile_count(257, 256); });
  // ipma encodes the count in exactly one byte: 255 is the representable bound.
  auto associated = fixture(1, 3, 255);
  require(read_heif(associated).item(1).properties.size() == 255, "association boundary rejected");
  for (auto count : {heif_limits::icc_bytes, heif_limits::icc_bytes + 1}) {
    auto b = fixture(1, 3, 3, count);
    if (count == heif_limits::icc_bytes)
      (void)read_heif(b);
    else
      rejects([&] { (void)read_heif(b); });
  }
  // Exercise bounded concatenation with both metadata and sample limits. Extent
  // validation is the same for file and idat; the public file retains spans.
  for (auto limit : {heif_limits::metadata_bytes, heif_limits::sample_bytes}) {
    Bytes data(limit + 1);
    HeifFile file;
    file.bytes = data;
    HeifItem item;
    item.id = 1;
    item.extents = {{0, limit}};
    file.items.emplace(1, item);
    require(file.item_bytes(1, limit).size() == limit, "payload boundary rejected");
    file.items[1].extents[0].length = limit + 1;
    rejects([&] { (void)file.item_bytes(1, limit); });
  }
  require(heif_add(UINT64_MAX - 1, 1) == UINT64_MAX, "64-bit boundary rejected");
  rejects([] { (void)heif_add(UINT64_MAX, 1); });
  auto config = f.resolve_image().config;
  auto hvcc = config.record;
  for(unsigned length_size : {1U,2U,4U}) {
    auto record=hvcc;record[21]=static_cast<std::uint8_t>((record[21]&252)|(length_size-1));
    auto parsed=parse_hevc_configuration(record);Bytes sample(length_size,0);sample.back()=4;sample.insert(sample.end(),{0x26,1,0x80,1});
    validate_hevc_sample(sample,parsed);
  }

  // Extra legal SEI arrays: the total NAL count, not just array count, is
  // bounded.
  for (unsigned n : {61U, 62U}) {
    auto c = hvcc;
    c[22] = 4;
    c.push_back(39);
    put16(c, n);
    for (unsigned i = 0; i < n; ++i) {
      put16(c, 3);
      c.insert(c.end(), {0x4e, 1, 0x80});
    }
    if (n == 61)
      require(parse_hevc_configuration(c).parameter_sets.size() == 64,
              "NAL count boundary rejected");
    else
      rejects([&] { (void)parse_hevc_configuration(c); });
  }
  {
    auto c = hvcc;
    c[22] = 4;
    c.push_back(39);
    put16(c, 1);
    put16(c, 65535);
    c.insert(c.end(), {0x4e, 1});
    c.resize(c.size() + 65533, 0x80);
    require(parse_hevc_configuration(c).parameter_sets.back().size() == 65535,
            "NAL size boundary rejected");
    auto zero_length = c;
    zero_length[hvcc.size() + 3] = 0;
    zero_length[hvcc.size() + 4] = 0;
    rejects([&] { (void)parse_hevc_configuration(zero_length); });
  }
  // SPS dimensions and sample validation do not require a raster allocation.
  Bytes sample(heif_limits::sample_bytes, 0);
  set32(sample, 0, sample.size() - 4);
  sample[4] = 0x26;
  sample[5] = 1;
  sample[6] = 0x80;  // first_slice_segment_in_pic_flag: one complete picture
  validate_hevc_sample(sample, config);
  sample.push_back(0);
  rejects([&] { validate_hevc_sample(sample, config); });
  require(raster_input_budget_ok(11656, 8742) && raster_input_budget_ok(8742, 11656),
          "raster admission boundary rejected");
  require(!raster_input_budget_ok(11657, 8742) && !raster_input_budget_ok(11656, 8743),
          "raster admission overflow accepted");
  std::cout << "HEIF resource boundaries passed on 512KiB stack\n";
}
void* entry(void* p) {
  try {
    run();
  } catch (...) {
    *static_cast<std::exception_ptr*>(p) = std::current_exception();
  }
  return nullptr;
}
}  // namespace
int main() {
  try {
    std::exception_ptr error;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_t thread;
    require(!pthread_create(&thread, &attr, entry, &error), "pthread_create");
    pthread_join(thread, nullptr);
    pthread_attr_destroy(&attr);
    if (error) std::rethrow_exception(error);
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}

// Bounded AVIF pull-row writer. libavif's AddImageGrid retains all input YUV
// cells and all codec contexts. Instead encode standalone cells sequentially,
// keep only their AV1 samples on disk, and assemble a standard HEIF image grid.
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/transfer.hpp"

#include <avif/avif.h>
#include <aom/aom_decoder.h>
#include <aom/aomdx.h>
#include "internal/avif_spool.hpp"
#include <algorithm>
#include <array>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <system_error>
#include <thread>
#include <unistd.h>

namespace hyperdr {
namespace {
using Bytes = std::vector<std::uint8_t>;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void check(avifResult r) { if (r != AVIF_RESULT_OK) throw std::runtime_error(std::string("AVIF: ") + avifResultToString(r)); }
void number(Bytes& b, std::uint64_t n, unsigned size) {
  for (unsigned i = size; i; --i) b.push_back(std::uint8_t(n >> ((i - 1) * 8)));
}
void text(Bytes& b, const std::string& s) { b.insert(b.end(), s.begin(), s.end()); }
void append(Bytes& b, std::span<const std::uint8_t> data) { b.insert(b.end(), data.begin(), data.end()); }
Bytes box(const char* type, const Bytes& payload) {
  require(payload.size() < UINT32_MAX - 8, "AVIF box too large");
  Bytes b; number(b, payload.size() + 8, 4); text(b, type); append(b, payload); return b;
}
Bytes full(unsigned version = 0, unsigned flags = 0) { Bytes b; number(b, (version << 24) | flags, 4); return b; }
Bytes ispe(unsigned w, unsigned h) { Bytes b = full(); number(b, w, 4); number(b, h, 4); return box("ispe", b); }
Bytes pixi() { Bytes b = full(); append(b, Bytes{3, 10, 10, 10}); return box("pixi", b); }
Bytes nclx(HdrEncoding encoding) {
  Bytes b; text(b, "nclx"); number(b, 9, 2); number(b, encoding == HdrEncoding::AvifPq ? 16 : 18, 2);
  number(b, 9, 2); number(b, 128, 1); return box("colr", b);
}

using internal::AvifSpool;
struct Item {
  std::string type;
  std::uint32_t offset{}, size{};
  bool hidden = false;
  std::vector<unsigned> properties;
};
struct Reference { std::string type; unsigned from; std::vector<unsigned> to; };

// iloc uses 32-bit offsets/lengths; bounds are checked before any publication.
// Only metadata lives in this vector. mdat is copied from the spool in chunks.
Bytes header(const std::vector<Item>& items, const std::vector<Bytes>& properties,
             const std::vector<Reference>& references, std::uint32_t media_size) {
  Bytes ftyp; text(ftyp, "avif"); number(ftyp, 0, 4); text(ftyp, "avifmif1miaf"); ftyp = box("ftyp", ftyp);
  auto metadata = [&](std::uint32_t media_offset) {
    Bytes meta = full();
    Bytes hdlr = full(); number(hdlr, 0, 4); text(hdlr, "pict"); number(hdlr, 0, 8); number(hdlr, 0, 4); hdlr.push_back(0); append(meta, box("hdlr", hdlr));
    Bytes pitm = full(); number(pitm, 1, 2); append(meta, box("pitm", pitm));
    Bytes iloc = full(); number(iloc, 0x4400, 2); number(iloc, items.size(), 2);
    Bytes iinf = full(); number(iinf, items.size(), 2);
    for (unsigned i = 0; i < items.size(); ++i) {
      const auto& item = items[i];
      require(std::uint64_t(media_offset) + item.offset + item.size <= UINT32_MAX, "AVIF exceeds 32-bit file limit");
      number(iloc, i + 1, 2); number(iloc, 0, 2); number(iloc, 1, 2);
      number(iloc, media_offset + item.offset, 4); number(iloc, item.size, 4);
      Bytes infe = full(2, item.hidden ? 1 : 0); number(infe, i + 1, 2); number(infe, 0, 2);
      text(infe, item.type); infe.push_back(0);
      if (item.type == "mime") { text(infe, "application/rdf+xml"); infe.push_back(0); infe.push_back(0); }
      append(iinf, box("infe", infe));
    }
    append(meta, box("iloc", iloc)); append(meta, box("iinf", iinf));
    if (!references.empty()) {
      Bytes iref = full();
      for (const auto& r : references) { Bytes b; number(b, r.from, 2); number(b, r.to.size(), 2); for (auto id : r.to) number(b, id, 2); append(iref, box(r.type.c_str(), b)); }
      append(meta, box("iref", iref));
    }
    Bytes ipco; for (const auto& p : properties) append(ipco, p);
    Bytes ipma = full(0, 1); number(ipma, items.size(), 4);
    for (unsigned i = 0; i < items.size(); ++i) {
      number(ipma, i + 1, 2); number(ipma, items[i].properties.size(), 1);
      for (auto p : items[i].properties) number(ipma, p | 0x8000, 2);
    }
    Bytes iprp = box("ipco", ipco); append(iprp, box("ipma", ipma)); append(meta, box("iprp", iprp));
    return box("meta", meta);
  };
  auto meta = metadata(0);
  const auto media_offset = ftyp.size() + meta.size() + 8;
  require(media_offset + media_size <= UINT32_MAX, "AVIF exceeds 32-bit file limit");
  meta = metadata(std::uint32_t(media_offset));
  append(ftyp, meta); number(ftyp, std::uint64_t(media_size) + 8, 4); text(ftyp, "mdat"); return ftyp;
}

// Native libavif writers emit the four-byte record without configOBUs. This
// output verifier deliberately refuses extensions rather than copying/skipping
// arbitrary configuration OBUs whose agreement with the sample is unproven.
void validate_config(std::span<const std::uint8_t> b) {
  require(b.size() == 4, "invalid native AVIF av1C length");
  require(b[0] == 0x81 && (b[1] >> 5) == 1 && ((b[1] & 31) <= 23 || (b[1] & 31) == 31) &&
          ((b[2] & 0x80) == 0 || (b[1] & 31) > 7) &&
          (b[2] & 0x7f) == 0x40 && (b[3] & 0xe0) == 0 &&
          ((b[3] & 0x10) != 0 || (b[3] & 0x0f) == 0), "invalid native AVIF av1C structure");
}
std::span<const std::uint8_t> property(const HeifFile& file, const HeifItem& item, const char* type) {
  std::span<const std::uint8_t> found;
  bool seen = false;
  for (const auto& p : item.properties) {
    const auto& value = file.properties.at(p.index - 1);
    if (value.type != type) continue;
    require(!seen, "duplicate AVIF item property");
    found = value.payload; seen = true;
  }
  require(seen, "missing AVIF item property");
  if (std::strcmp(type, "av1C") == 0) validate_config(found);
  if (std::strcmp(type, "ispe") == 0)
    require(found.size() == 12 && std::all_of(found.begin(), found.begin() + 4, [](auto v) { return v == 0; }), "invalid AVIF ispe");
  if (std::strcmp(type, "pixi") == 0) {
    constexpr std::array<std::uint8_t, 8> expected{0, 0, 0, 0, 3, 10, 10, 10};
    require(std::equal(found.begin(), found.end(), expected.begin(), expected.end()), "invalid AVIF 10-bit RGB pixi");
  }
  return found;
}

// libavif 1.4.2 read.c: Parse -> Reset builds empty images and tile/sample
// tables; codecs and canvas planes are created only by NextImage. Ignore
// Exif/XMP, bound non-media boxes (including copied idat/opaque properties),
// and validate av1C/grid lengths BEFORE giving the original container to it.
void parse_original(const HeifFile& file) {
  std::uint64_t metadata_size = 0;
  for (const auto& b : file.boxes) if (b.depth == 0 && b.type != "mdat") {
    require(b.size <= heif_limits::metadata_bytes - metadata_size, "AVIF container metadata too large");
    metadata_size += b.size;
  }
  for (const auto& p : file.properties) if (p.type == "av1C") validate_config(p.payload);
  for (const auto& entry : file.items) {
    const auto& item = entry.second;
    std::uint64_t size = 0;
    const auto limit = item.type == "grid" ? 12 : heif_limits::sample_bytes;
    for (const auto& extent : item.extents) {
      require(extent.length <= limit - size, "AVIF item exceeds bounded size");
      size += extent.length;
    }
  }
  std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> decoder(avifDecoderCreate(), &avifDecoderDestroy);
  require(bool(decoder), "allocate AVIF parser failed");
  decoder->maxThreads = 1; decoder->ignoreExif = AVIF_TRUE; decoder->ignoreXMP = AVIF_TRUE;
  check(avifDecoderSetSource(decoder.get(), AVIF_DECODER_SOURCE_PRIMARY_ITEM));
  check(avifDecoderSetIOMemory(decoder.get(), file.bytes.data(), file.bytes.size()));
  check(avifDecoderParse(decoder.get()));
  require(!decoder->alphaPresent && decoder->image && decoder->image->depth == 10 &&
          decoder->image->yuvFormat == AVIF_PIXEL_FORMAT_YUV444, "invalid AVIF grid pixel format");
  // Do not call NextImage on the original grid: that allocates its canvas.
}

// Decode the original AV1 sample directly: libavif would silently scale it to
// ispe and let colr override its CICP/range. The external buffer cap additionally
// prevents a later sequence header from requesting a canvas-sized frame.
void verify_cell(std::span<const std::uint8_t> sample, unsigned w, unsigned h, HdrEncoding encoding) {
  aom_codec_stream_info_t info{};
  require(aom_codec_peek_stream_info(aom_codec_av1_dx(), sample.data(), sample.size(), &info) == AOM_CODEC_OK &&
          info.w == w && info.h == h, "AVIF codec dimensions differ from ispe");
  struct Buffers {
    std::size_t used = 0, limit;
    static int get(void* opaque, std::size_t size, aom_codec_frame_buffer_t* b) {
      auto& self = *static_cast<Buffers*>(opaque);
      if (size > self.limit - self.used) return -1;
      b->data = static_cast<std::uint8_t*>(std::calloc(size, 1));
      if (!b->data) return -1;
      b->size = size; self.used += size; return 0;
    }
    static int release(void* opaque, aom_codec_frame_buffer_t* b) {
      auto& self = *static_cast<Buffers*>(opaque);
      self.used -= b->size; std::free(b->data); b->data = nullptr; b->size = 0; return 0;
    }
  } buffers{0, std::size_t(2 * avif_single_frame_bytes(w, h))};
  aom_codec_ctx_t decoder{};
  aom_codec_dec_cfg_t config{}; config.threads = 1;
  require(aom_codec_dec_init(&decoder, aom_codec_av1_dx(), &config, 0) == AOM_CODEC_OK, "allocate AV1 verifier failed");
  struct Guard { aom_codec_ctx_t* decoder; ~Guard() { aom_codec_destroy(decoder); } } guard{&decoder};
  require(aom_codec_set_frame_buffer_functions(&decoder, &Buffers::get, &Buffers::release, &buffers) == AOM_CODEC_OK,
          "set AV1 verification buffer bound failed");
  require(aom_codec_decode(&decoder, sample.data(), sample.size(), nullptr) == AOM_CODEC_OK, "decode AVIF cell failed");
  aom_codec_iter_t iterator = nullptr;
  const auto* image = aom_codec_get_frame(&decoder, &iterator);
  require(image && image->d_w == w && image->d_h == h && image->bit_depth == 10 &&
          !image->monochrome && image->x_chroma_shift == 0 && image->y_chroma_shift == 0 &&
          image->range == AOM_CR_FULL_RANGE, "invalid AVIF codec dimensions/10-bit 444/range");
  const auto transfer = encoding == HdrEncoding::AvifPq ? 16 : 18;
  // libavif's AOM encoder intentionally writes 2/2/2 in the OBU, with the
  // authoritative Rec.2020 PQ/HLG CICP in colr (codec_aom.c). Other CICP must agree.
  require((int(image->cp) == 2 && int(image->tc) == 2 && int(image->mc) == 2) ||
          (int(image->cp) == 9 && int(image->tc) == transfer && int(image->mc) == 9), "AVIF codec color differs from colr");
  require(!aom_codec_get_frame(&decoder, &iterator), "AVIF cell contains multiple frames");
}
// Identifies a cell sample the writer has already decoded, so the check of the
// finished file can match its bytes instead of decoding them a second time.
// Not a security digest: it notices a wrong offset or a torn write.
std::uint64_t sample_digest(std::span<const std::uint8_t> bytes) {
  std::uint64_t hash = 14695981039346656037ULL;
  for (const auto byte : bytes) { hash ^= byte; hash *= 1099511628211ULL; }
  return hash;
}

// Decodes each coded cell on one worker thread while the next cell encodes, so
// checking every sample costs little beyond the encode. At most two samples
// wait (one decoder of the cell's size is resident); a failure surfaces at the
// writer's next cell. The worker runs no engine entry point and never reads the
// caller's cancel token: the package thread checks it between cells.
class CellVerifier {
 public:
  CellVerifier(unsigned width, unsigned height, HdrEncoding encoding)
      : width_(width), height_(height), encoding_(encoding), worker_([this] { run(); }) {}
  ~CellVerifier() {
    { std::lock_guard lock(mutex_); closing_ = true; jobs_.clear(); }
    work_.notify_all();
    worker_.join();
  }
  CellVerifier(const CellVerifier&) = delete;
  CellVerifier& operator=(const CellVerifier&) = delete;

  void submit(Bytes sample) {
    std::unique_lock lock(mutex_);
    changed_.wait(lock, [&] { return jobs_.size() < 2 || failure_; });
    if (failure_) std::rethrow_exception(failure_);
    jobs_.push_back(std::move(sample));
    work_.notify_all();
  }
  [[nodiscard]] std::uint32_t verified() {
    std::lock_guard lock(mutex_);
    if (failure_) std::rethrow_exception(failure_);
    return done_;
  }
  // Waits for every submitted sample, reporting each one as it is checked.
  void drain(std::uint32_t total, std::uint32_t reported) {
    std::unique_lock lock(mutex_);
    for (;;) {
      changed_.wait(lock, [&] { return failure_ || done_ != reported || (jobs_.empty() && !busy_); });
      if (failure_) std::rethrow_exception(failure_);
      if (done_ != reported) {
        reported = done_;
        lock.unlock();
        check_cancelled();
        report_package_progress(PackagePhase::VerifyCells, reported, total);
        check_cancelled();
        lock.lock();
      }
      if (jobs_.empty() && !busy_ && done_ == reported) return;
    }
  }

 private:
  void run() {
    std::unique_lock lock(mutex_);
    for (;;) {
      work_.wait(lock, [&] { return closing_ || !jobs_.empty(); });
      if (closing_) return;
      auto sample = std::move(jobs_.front());
      jobs_.pop_front(); busy_ = true;
      lock.unlock();
      std::exception_ptr error;
      try { verify_cell(sample, width_, height_, encoding_); } catch (...) { error = std::current_exception(); }
      lock.lock(); busy_ = false;
      if (error) failure_ = error; else ++done_;
      changed_.notify_all();
      if (failure_) return;
    }
  }

  const unsigned width_, height_;
  const HdrEncoding encoding_;
  std::mutex mutex_;
  std::condition_variable work_, changed_;
  std::deque<Bytes> jobs_;
  bool closing_ = false, busy_ = false;
  std::uint32_t done_ = 0;
  std::exception_ptr failure_;
  std::thread worker_;  // Last: it starts once every member above exists.
};

unsigned be32(std::span<const std::uint8_t> b, std::size_t p) {
  require(p <= b.size() && b.size() - p >= 4, "truncated AVIF dimensions");
  return (unsigned(b[p]) << 24) | (unsigned(b[p + 1]) << 16) | (unsigned(b[p + 2]) << 8) | b[p + 3];
}
} // namespace

AvifCellDigests write_avif_rows(const EncodingRows& base, const EncodingRows& codes,
    const GainMapMetadata& metadata, float headroom, const PhotoMetadata& photo,
    HdrEncoding encoding, int quality, const std::filesystem::path& path, bool verify_cells) {
  if (!is_avif_encoding(encoding) || !base.width || !base.height || base.channels != 3 ||
      codes.width != base.width || codes.height != base.height || (codes.channels != 1 && codes.channels != 3) || !base.read || !codes.read)
    throw std::invalid_argument("invalid AVIF row input");
  if (!avif_canvas_decodable(base.width, base.height)) throw ExportDimensionLimit::avif(base.width, base.height);
  const auto layout = avif_row_grid_layout(base.width, base.height);
  require(layout.cell_width <= kAvifRowMaxCellSide && layout.cell_height <= kAvifRowMaxCellSide,
          "AVIF row cell exceeds writer budget");
  AvifSpool pixels(path), samples(path);
  FloatImage b(base.width, 1, 3), g(base.width, 1, codes.channels), hdr(base.width, 1, 3);
  std::vector<std::uint16_t> rgb_row(std::size_t(base.width) * 3);
  float peak = 0; double light = 0;
  for (unsigned y = 0; y < base.height; ++y) {
    check_cancelled(); base.read(y, b.pixels); codes.read(y, g.pixels);
    reconstruct_gain_map_into(hdr, b, g, metadata, headroom);
    for (unsigned x = 0; x < base.width; ++x) {
      const auto wide = p3_to_rec2020(hdr.at(x, 0, 0), hdr.at(x, 0, 1), hdr.at(x, 0, 2));
      const std::array<float, 3> linear{std::max(0.f, wide[0]), std::max(0.f, wide[1]), std::max(0.f, wide[2])};
      const auto level = std::max({linear[0], linear[1], linear[2]}); peak = std::max(peak, level); light += level;
      const auto encoded = encoding == HdrEncoding::AvifPq ? std::array<float, 3>{pq_oetf(linear[0]), pq_oetf(linear[1]), pq_oetf(linear[2])} : hlg_encode(linear);
      for (unsigned c = 0; c < 3; ++c) rgb_row[x * 3 + c] = std::uint16_t(quantize_dithered(encoded[c], 1023, x, y, c));
    }
    pixels.write({reinterpret_cast<const std::uint8_t*>(rgb_row.data()), rgb_row.size() * 2});
  }
  const auto clamp_light = [](double v) { return std::uint16_t(std::clamp(std::ceil(v), 0., 10000.)); };
  Bytes clli; number(clli, clamp_light(peak * kReferenceWhiteNits), 2);
  number(clli, clamp_light(light * kReferenceWhiteNits / (double(base.width) * base.height)), 2);
  std::vector<Bytes> properties{ispe(base.width, base.height), pixi(), nclx(encoding), box("clli", clli), ispe(layout.cell_width, layout.cell_height)};
  Bytes grid{0, 1, std::uint8_t(layout.rows - 1), std::uint8_t(layout.columns - 1)};
  number(grid, base.width, 4); number(grid, base.height, 4);
  std::vector<Item> items{{"grid", 0, std::uint32_t(grid.size()), false, {1, 2, 3, 4}}};
  std::vector<Reference> references{{"dimg", 1, {}}};
  samples.write(grid);
  std::uint64_t media_size = grid.size();
  Bytes config;
  const auto cells = layout.rows * layout.columns;
  AvifCellDigests decoded;
  std::optional<CellVerifier> verifier;
  if (verify_cells) {
    verifier.emplace(layout.cell_width, layout.cell_height, encoding);
    decoded.samples.reserve(cells);
    decoded.width = layout.cell_width; decoded.height = layout.cell_height; decoded.encoding = encoding;
  }
  std::uint32_t encoded = 0, reported_verified = 0;
  for (unsigned cy = 0; cy < layout.rows; ++cy) for (unsigned cx = 0; cx < layout.columns; ++cx) {
    check_cancelled();
    std::unique_ptr<avifImage, decltype(&avifImageDestroy)> image(avifImageCreate(layout.cell_width, layout.cell_height, 10, AVIF_PIXEL_FORMAT_YUV444), &avifImageDestroy);
    require(bool(image), "allocate AVIF cell failed");
    image->yuvRange = AVIF_RANGE_FULL; image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    image->transferCharacteristics = encoding == HdrEncoding::AvifPq ? AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084 : AVIF_TRANSFER_CHARACTERISTICS_HLG;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    avifRGBImage rgb{}; avifRGBImageSetDefaults(&rgb, image.get()); rgb.format = AVIF_RGB_FORMAT_RGB; rgb.depth = 10;
    check(avifRGBImageAllocatePixels(&rgb));
    struct RGBGuard { avifRGBImage* rgb; ~RGBGuard() { avifRGBImageFreePixels(rgb); } } guard{&rgb};
    const unsigned x0 = cx * layout.cell_width, y0 = cy * layout.cell_height;
    const unsigned valid_width = std::min(layout.cell_width, base.width - x0);
    for (unsigned y = 0; y < layout.cell_height; ++y) {
      const auto source_y = std::min(y0 + y, base.height - 1);
      pixels.seek((std::uint64_t(source_y) * base.width + x0) * 6);
      auto* row = rgb.pixels + std::size_t(y) * rgb.rowBytes;
      pixels.read({row, std::size_t(valid_width) * 6});
      for (unsigned x = valid_width; x < layout.cell_width; ++x) std::memcpy(row + x * 6, row + (valid_width - 1) * 6, 6);
    }
    check(avifImageRGBToYUV(image.get(), &rgb));
    std::unique_ptr<avifEncoder, decltype(&avifEncoderDestroy)> encoder(avifEncoderCreate(), &avifEncoderDestroy);
    require(bool(encoder), "allocate AVIF encoder failed");
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    encoder->quality = std::clamp(quality, 0, 100); encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS; encoder->speed = 6;
    encoder->maxThreads = int(std::min(unsigned(kAvifRowMaxThreads), std::max(1U, std::thread::hardware_concurrency())));
    avifRWData output = AVIF_DATA_EMPTY;
    struct OutputGuard { avifRWData* data; ~OutputGuard() { avifRWDataFree(data); } } output_guard{&output};
    check(avifEncoderWrite(encoder.get(), image.get(), &output));
    const auto file = read_heif({output.data, output.size});
    const auto& item = file.item(file.primary_item_id);
    require(item.type == "av01", "AVIF cell is not AV1");
    const auto cell_config = property(file, item, "av1C");
    if (config.empty()) { config.assign(cell_config.begin(), cell_config.end()); properties.push_back(box("av1C", config)); }
    else require(std::equal(cell_config.begin(), cell_config.end(), config.begin(), config.end()), "AVIF cell configurations differ");
    const auto sample = file.item_bytes(item.id);
    require(media_size + sample.size() <= UINT32_MAX, "AVIF exceeds 32-bit file limit");
    references.front().to.push_back(unsigned(items.size() + 1));
    items.push_back({"av01", std::uint32_t(media_size), std::uint32_t(sample.size()), true, {5, 2, 3, 6}});
    samples.write(sample); media_size += sample.size();
    if (verifier) {
      decoded.samples.push_back(sample_digest(sample));
      verifier->submit(Bytes(sample.begin(), sample.end()));
    }
    check_cancelled();
    report_package_progress(PackagePhase::EncodeCells, ++encoded, cells);
    check_cancelled();
    if (verifier) {
      reported_verified = verifier->verified();
      check_cancelled();
      report_package_progress(PackagePhase::VerifyCells, reported_verified, cells);
      check_cancelled();
    }
  }
  if (verifier) { verifier->drain(cells, reported_verified); verifier.reset(); }
  auto add_metadata = [&](const char* type, const Bytes& bytes) {
    require(media_size + bytes.size() <= UINT32_MAX, "AVIF metadata too large");
    items.push_back({type, std::uint32_t(media_size), std::uint32_t(bytes.size()), false, {}});
    references.push_back({"cdsc", unsigned(items.size()), {1}}); samples.write(bytes); media_size += bytes.size();
  };
  auto exif = make_minimal_exif(photo); Bytes exif_item(4, 0); append(exif_item, exif); add_metadata("Exif", exif_item);
  const auto xmp = make_xmp(photo, headroom, false); add_metadata("mime", Bytes(xmp.begin(), xmp.end()));
  const auto prefix = header(items, properties, references, std::uint32_t(media_size));
  std::unique_ptr<FILE, decltype(&fclose)> destination(fopen(path.c_str(), "wb"), &fclose);
  require(bool(destination), "open AVIF destination failed");
  require(fwrite(prefix.data(), 1, prefix.size(), destination.get()) == prefix.size(), "write AVIF header failed");
  samples.seek(0); std::array<std::uint8_t, 65536> chunk{};
  for (std::uint64_t left = media_size; left;) {
    check_cancelled(); const auto count = std::min<std::uint64_t>(left, chunk.size());
    samples.read(std::span(chunk).first(count));
    require(fwrite(chunk.data(), 1, count, destination.get()) == count, "write AVIF samples failed"); left -= count;
  }
  require(fclose(destination.release()) == 0, "close AVIF destination failed");
  return decoded;
}

VerificationResult verify_avif_pixels(std::span<const std::uint8_t> bytes, const AvifCellDigests* decoded) {
  const auto file = read_heif(bytes);
  const auto& primary = file.item(file.primary_item_id);
  VerificationResult result;
  const auto dimensions = property(file, primary, "ispe");
  result.width = be32(dimensions, 4); result.height = be32(dimensions, 8);
  result.pixels = std::uint64_t(result.width) * result.height;
  require(result.width && result.height && avif_canvas_decodable(result.width, result.height), "invalid AVIF canvas");
  if (primary.type != "grid") {
    verify_avif_decodable(bytes); result.boundedMemory = false; return result;
  }
  const auto grid = file.item_bytes(primary.id, 12);
  // The old libavif grid writer uses 16-bit dimensions (8 bytes); the row
  // writer uses 32-bit dimensions (12 bytes). Both share the same 12-byte cap.
  require((grid.size() == 8 || grid.size() == 12) && grid[0] == 0 &&
          grid[1] == (grid.size() == 12 ? 1 : 0), "invalid AVIF grid descriptor");
  const auto grid_width = grid.size() == 12 ? be32(grid, 4) : (unsigned(grid[4]) << 8) | grid[5];
  const auto grid_height = grid.size() == 12 ? be32(grid, 8) : (unsigned(grid[6]) << 8) | grid[7];
  require(grid_width == result.width && grid_height == result.height, "AVIF grid crop/ispe mismatch");
  const unsigned rows = unsigned(grid[2]) + 1, columns = unsigned(grid[3]) + 1;
  const auto cells = file.targets(primary.id, "dimg");
  require(cells.size() == rows * columns, "AVIF grid cell count differs");
  const auto color = property(file, primary, "colr");
  require(color.size() == 11 && std::memcmp(color.data(), "nclx", 4) == 0 && color[4] == 0 && color[5] == 9 && color[6] == 0 && (color[7] == 16 || color[7] == 18) && color[8] == 0 && color[9] == 9 && color[10] == 128, "invalid AVIF grid color");
  const auto encoding = color[7] == 16 ? HdrEncoding::AvifPq : HdrEncoding::AvifHlg;
  (void)property(file, primary, "pixi");
  parse_original(file); // Reject unknown essential properties on grid AND cells.
  // A writer that decoded its cells as it coded them hands over their digests:
  // a sample whose bytes and decode parameters match was decoded already;
  // any other is decoded here against the finished file's metadata.
  require(!decoded || decoded->samples.empty() || decoded->samples.size() == cells.size(),
          "AVIF decoded cell count differs");
  unsigned cell_width = 0, cell_height = 0;
  std::size_t index = 0;
  for (auto id : cells) {
    check_cancelled(); const auto& item = file.item(id);
    require(item.type == "av01", "AVIF grid cell is not AV1");
    const auto size = property(file, item, "ispe");
    const unsigned w = be32(size, 4), h = be32(size, 8);
    if (!cell_width) { cell_width = w; cell_height = h; }
    require(w == cell_width && h == cell_height && w && h && w <= kAvifVerifyMaxCellSide && h <= kAvifVerifyMaxCellSide, "invalid AVIF cell dimensions");
    (void)property(file, item, "av1C");
    (void)property(file, item, "pixi");
    const auto cell_color = property(file, item, "colr");
    require(std::equal(cell_color.begin(), cell_color.end(), color.begin(), color.end()), "AVIF cell/grid color differs");
    const auto sample = file.item_bytes(id);
    const bool seen = decoded && decoded->width == w && decoded->height == h && decoded->encoding == encoding &&
        index < decoded->samples.size() && decoded->samples[index] == sample_digest(sample);
    if (!seen) verify_cell(sample, w, h, encoding);
    ++index;
  }
  require(std::uint64_t(cell_width) * (columns - 1) < result.width && std::uint64_t(cell_width) * columns >= result.width &&
          std::uint64_t(cell_height) * (rows - 1) < result.height && std::uint64_t(cell_height) * rows >= result.height, "AVIF grid does not cover canvas");
  return result;
}
} // namespace hyperdr

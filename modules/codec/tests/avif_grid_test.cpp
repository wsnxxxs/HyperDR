// E8: canvases libaom cannot hold as one frame are written as AVIF grids.
// Covers the layout rule at its boundaries, a cell-for-cell comparison with the
// single-item encoding (libavif and ImageIO both decode it), and the guard that
// keeps ordinary canvases byte-for-byte on the single-item path.
#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/codec/avif_grid.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "internal/decode_bytes.hpp"
#include "internal/avif_spool.hpp"
#include <sys/stat.h>

#include <avif/avif.h>
#include <pthread.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cmath>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <thread>

namespace {
using namespace hyperdr;

void require(bool ok, const std::string& message) {
  if (!ok) throw std::runtime_error(message);
}

void layout_rule() {
  constexpr std::uint32_t kMax = kAvifMaxCellSide;
  // Measured against libaom: these encode as one item.
  for (auto [w, h] : {std::pair{9504U, 6336U}, {11000U, 11000U}, {20000U, 6000U}, {6000U, 20000U},
                      {128U, 128U}, {65535U, 8U}, {8U, 65535U}, {1U, 1U}}) {
    const auto layout = avif_grid_layout(w, h);
    require(!layout.is_grid() && layout.cell_width == w && layout.cell_height == h,
            "an encodable canvas left the single-item layout");
  }
  // The libaom limit itself: 11800x11800 encodes, 12000x12000 and the 61 MP
  // story canvas do not. The rule has a 10% margin below the limit.
  require(avif_single_frame_bytes(11800, 11800) < kAvifLibaomFrameLimit &&
              avif_single_frame_bytes(12000, 12000) > kAvifLibaomFrameLimit &&
              avif_single_frame_bytes(10200, 18134) > kAvifLibaomFrameLimit,
          "frame size model no longer matches libaom's measured limit");
  require(!avif_grid_layout(11000, 11000).is_grid() && avif_grid_layout(11800, 11800).is_grid() &&
              avif_grid_layout(12000, 12000).is_grid(),
          "grid threshold moved");
  // The first canvas over the margin switches, one pixel less does not.
  std::uint32_t w = 10000;
  while (!avif_grid_layout(w, w).is_grid()) ++w;
  require(avif_single_frame_bytes(w, w) > kAvifSingleFrameBudget &&
              avif_single_frame_bytes(w - 1, w - 1) <= kAvifSingleFrameBudget,
          "grid boundary is not the budget");
  // Every grid: tiles the canvas exactly, cells at most the cap, a remainder
  // never larger than a cell and never a sliver, libavif's 256 limit respected.
  for (auto [cw, ch] : {std::pair{10200U, 18134U}, {w, w}, {65535U, 2000U}, {2000U, 65535U},
                        {65535U, 65535U}, {30000U, 9000U}, {12000U, 12000U}, {11801U, 11801U}}) {
    const auto layout = avif_grid_layout(cw, ch);
    require(layout.is_grid() && layout.columns <= 256 && layout.rows <= 256,
            "oversize canvas stayed a single item");
    require(layout.cell_width <= kMax && layout.cell_height <= kMax && layout.cell_width > 0 &&
                layout.cell_height > 0, "cell larger than the cap");
    const auto last_w = cw - (layout.columns - 1) * layout.cell_width;
    const auto last_h = ch - (layout.rows - 1) * layout.cell_height;
    require(last_w > 0 && last_w <= layout.cell_width && last_h > 0 && last_h <= layout.cell_height,
            "grid does not tile the canvas");
    require(last_w * 2 > layout.cell_width && last_h * 2 > layout.cell_height,
            "grid ends in a sliver");
    require(avif_single_frame_bytes(layout.cell_width, layout.cell_height) <= kAvifSingleFrameBudget,
            "a cell is still too large for libaom");
  }
  const auto story = avif_grid_layout(10200, 18134);
  require(story.columns == 3 && story.rows == 5 && story.cell_width == 3456 && story.cell_height == 3648,
          "61 MP story layout changed");
  // Cells are a multiple of 64 wherever an axis has more than one (MIAF), never
  // above the cap, and an axis with one cell is not padded.
  for (auto [cw, ch] : {std::pair{10200U, 18134U}, {12000U, 12000U}, {11801U, 11801U}, {65535U, 2000U},
                        {2000U, 65535U}, {30000U, 9000U}, {w, w}}) {
    const auto layout = avif_grid_layout(cw, ch);
    require(layout.columns == 1 ? layout.cell_width == cw : layout.cell_width % 64 == 0, "cell width not a multiple of 64");
    require(layout.rows == 1 ? layout.cell_height == ch : layout.cell_height % 64 == 0, "cell height not a multiple of 64");
    require(layout.cell_width <= kMax && layout.cell_height <= kMax, "aligned cell above the cap");
  }
  // What libavif decodes: 16384x16384 pixels and 32768 per side, whatever we encode.
  require(avif_canvas_decodable(16384, 16384) && !avif_canvas_decodable(16385, 16384) &&
              avif_canvas_decodable(32768, 8192) && !avif_canvas_decodable(32769, 2) &&
              !avif_canvas_decodable(2, 32769) && avif_canvas_decodable(9504, 6336) &&
              avif_canvas_decodable(10200, 18134) && !avif_canvas_decodable(12672, 22528),
          "AVIF decodable limit moved");
}

void row_layout_rule() {
  for (auto [w, h] : {std::pair{1U, 1U}, {63U, 1025U}, {1024U, 1024U}, {1025U, 1025U},
                      {9504U, 6336U}, {10200U, 18134U}, {32768U, 8192U}, {8192U, 32768U}}) {
    const auto l = avif_row_grid_layout(w, h);
    require(l.columns && l.rows && l.columns <= 256 && l.rows <= 256 &&
            l.cell_width <= kAvifRowMaxCellSide && l.cell_height <= kAvifRowMaxCellSide &&
            l.cell_width % 64 == 0 && l.cell_height % 64 == 0,
            "row AVIF cell allocation is not bounded/aligned");
    require((l.columns - 1) * l.cell_width < w && l.columns * l.cell_width >= w &&
            (l.rows - 1) * l.cell_height < h && l.rows * l.cell_height >= h,
            "row AVIF grid does not cover the native canvas");
  }
  const auto l = avif_row_grid_layout(9504, 6336);
  require(l.columns == 10 && l.rows == 7 && l.cell_width == 960 && l.cell_height == 960 &&
          kAvifRowMaxThreads == 4, "61 MP row allocation constants changed; mirror in host budgets");
}

FloatImage make_hdr(std::uint32_t width, std::uint32_t height) {
  FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y)
    for (std::uint32_t x = 0; x < width; ++x) {
      const float u = float(x) / width, v = float(y) / height;
      const bool tile = ((x / 17) + (y / 13)) % 2;
      image.at(x, y, 0) = 0.05F + 3.0F * u * u;
      image.at(x, y, 1) = 0.02F + 1.5F * v + (tile ? 0.2F : 0.0F);
      image.at(x, y, 2) = 0.1F + 0.8F * std::sin((x + 2 * y) * 0.07F) * std::sin((x + 2 * y) * 0.07F);
    }
  return image;
}

struct Decoded {
  std::uint32_t width{}, height{};
  std::vector<std::uint16_t> rgb;  // 10-bit codes, interleaved
  avifPixelFormat format{};
  avifTransferCharacteristics transfer{};
  std::uint16_t max_cll{}, max_pall{};
  std::size_t exif{}, xmp{};
};

Decoded libavif_decode(const std::vector<std::uint8_t>& bytes) {
  std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> decoder(avifDecoderCreate(), &avifDecoderDestroy);
  decoder->maxThreads = 1;
  require(avifDecoderSetIOMemory(decoder.get(), bytes.data(), bytes.size()) == AVIF_RESULT_OK &&
              avifDecoderParse(decoder.get()) == AVIF_RESULT_OK &&
              avifDecoderNextImage(decoder.get()) == AVIF_RESULT_OK, "libavif cannot decode the file");
  const auto* image = decoder->image;
  Decoded d;
  d.width = image->width;
  d.height = image->height;
  d.format = image->yuvFormat;
  d.transfer = image->transferCharacteristics;
  d.max_cll = image->clli.maxCLL;
  d.max_pall = image->clli.maxPALL;
  d.exif = image->exif.size;
  d.xmp = image->xmp.size;
  require(image->depth == 10, "not 10-bit");
  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, image);
  rgb.format = AVIF_RGB_FORMAT_RGB;
  rgb.depth = 10;
  require(avifRGBImageAllocatePixels(&rgb) == AVIF_RESULT_OK && avifImageYUVToRGB(image, &rgb) == AVIF_RESULT_OK,
          "libavif YUV to RGB failed");
  d.rgb.resize(std::size_t(d.width) * d.height * 3);
  for (std::uint32_t y = 0; y < d.height; ++y)
    std::memcpy(&d.rgb[std::size_t(y) * d.width * 3], rgb.pixels + std::size_t(y) * rgb.rowBytes, d.width * 6);
  avifRGBImageFreePixels(&rgb);
  return d;
}

// What Photos and Preview do: ImageIO decodes to 16-bit in the file's own colour space.
std::vector<std::uint16_t> imageio_decode(const std::vector<std::uint8_t>& bytes, bool pq,
                                          std::uint32_t& width, std::uint32_t& height) {
  auto data = CFDataCreate(nullptr, bytes.data(), CFIndex(bytes.size()));
  auto source = CGImageSourceCreateWithData(data, nullptr);
  CFRelease(data);
  require(source != nullptr, "ImageIO does not recognise the AVIF");
  auto image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CFRelease(source);
  require(image != nullptr, "ImageIO cannot decode the AVIF");
  width = std::uint32_t(CGImageGetWidth(image));
  height = std::uint32_t(CGImageGetHeight(image));
  auto space = CGColorSpaceCreateWithName(pq ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceITUR_2100_HLG);
  std::vector<std::uint16_t> pixels(std::size_t(width) * height * 4);
  auto context = CGBitmapContextCreate(pixels.data(), width, height, 16, std::size_t(width) * 8, space,
                                       kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder16Little);
  CGColorSpaceRelease(space);
  require(context != nullptr, "cannot create the ImageIO comparison context");
  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
  CGContextRelease(context);
  CGImageRelease(image);
  return pixels;
}

void grid_matches_single_item() {
  PhotoMetadata metadata;
  metadata.orientation = 1;
  for (const auto encoding : {HdrEncoding::AvifPq, HdrEncoding::AvifHlg}) {
    const bool pq = encoding == HdrEncoding::AvifPq;
    for (auto [w, h] : {std::pair{384U, 256U}, {515U, 261U}}) {
      PhotoRenditions renditions;
      renditions.hdr = make_hdr(w, h);
      renditions.stats.headroom_stops = 2.0F;
      const auto single = encode_avif(renditions, metadata, 100, encoding);
      // The default layout of a small canvas is the single item, as before.
      const AvifGridLayout one{1, 1, w, h};
      require(encode_avif(renditions, metadata, 100, encoding, &one) == single,
              "an explicit single-item layout changed the bytes");
      const auto reference = libavif_decode(single);
      std::uint32_t iw = 0, ih = 0;
      const auto reference_io = imageio_decode(single, pq, iw, ih);
      require(iw == w && ih == h, "ImageIO changed the single-item size");
      struct Case { const char* name; AvifGridLayout layout; };
      for (const Case c : {Case{"2x2", {2, 2, (w + 1) / 2, (h + 1) / 2}},
                           Case{"3x2 ragged", {3, 2, (w + 2) / 3, (h + 1) / 2}},
                           Case{"1x4", {1, 4, w, (h + 3) / 4}},
                           Case{"5x1", {5, 1, (w + 4) / 5, h}},
                           Case{"last column 1 px", {2, 1, w - 1, h}}}) {
        const auto grid = encode_avif(renditions, metadata, 100, encoding, &c.layout);
        verify_avif_decodable(grid);
        const auto verified = verify_avif_pixels(grid);
        require(verified.boundedMemory && verified.width == w && verified.height == h &&
                    verified.pixels == std::uint64_t(w) * h,
                std::string("legacy grid lost bounded verification: ") + c.name);
        const auto got = libavif_decode(grid);
        require(got.width == w && got.height == h && got.format == AVIF_PIXEL_FORMAT_YUV444 &&
                    got.transfer == reference.transfer, std::string("grid changed the image shape: ") + c.name);
        require(got.max_cll == reference.max_cll && got.max_pall == reference.max_pall,
                std::string("grid changed the content light level: ") + c.name);
        require(got.exif > 0 && got.xmp > 0, std::string("grid dropped the metadata: ") + c.name);
        std::size_t differing = 0;
        int largest = 0;
        for (std::size_t i = 0; i < got.rgb.size(); ++i) {
          const int d = std::abs(int(got.rgb[i]) - int(reference.rgb[i]));
          differing += d != 0;
          largest = std::max(largest, d);
        }
        // Same codes in every cell; the codec only has independent prediction at the seams.
        require(largest <= 4 && differing * 50 < got.rgb.size(),
                std::string("grid decodes differently from the single item: ") + c.name);
        std::uint32_t gw = 0, gh = 0;
        const auto io = imageio_decode(grid, pq, gw, gh);
        require(gw == w && gh == h, std::string("ImageIO changed the grid size: ") + c.name);
        // ImageIO on the grid must agree with ImageIO on the single item to within what the codec does at seams.
        std::size_t io_differing = 0;
        int io_largest = 0;
        for (std::size_t i = 0; i < io.size(); ++i) {
          if (i % 4 == 3) continue;
          const int d = std::abs(int(io[i]) - int(reference_io[i]));
          io_differing += d > 256;  // 4 ten-bit codes
          io_largest = std::max(io_largest, d);
        }
        require(io_differing * 50 < io.size(),
                std::string("ImageIO decodes the grid differently: ") + c.name);
        (void)io_largest;
      }
    }
  }
}

void pull_rows_match_native_codes() {
  const auto path = test::temporary_directory() / "rows.avif";
  PhotoMetadata metadata; metadata.orientation = 1;
  for (const auto encoding : {HdrEncoding::AvifPq, HdrEncoding::AvifHlg}) {
    for (auto [w, h] : {std::pair{1031U, 1027U}, {65U, 1031U}, {1U, 1U}}) {
      PhotoRenditions renditions; renditions.hdr = make_hdr(w, h); renditions.stats.headroom_stops = 2;
      const auto reference = libavif_decode(encode_avif(renditions, metadata, 100, encoding));
      EncodingRows base{w, h, 3, [&](unsigned y, std::span<float> out) {
        std::copy_n(renditions.hdr.pixels.data() + std::size_t(y) * w * 3, out.size(), out.data());
      }};
      EncodingRows gain{w, h, 1, [](unsigned, std::span<float> out) { std::fill(out.begin(), out.end(), 0.f); }};
      GainMapMetadata map; map.alternate_headroom = {2, 1};
      write_avif_rows(base, gain, map, 2, metadata, encoding, 100, path);
      const auto bytes = read_binary_file(path);
      const auto got = libavif_decode(bytes);
      const auto verified = verify_encoded_file(path, encoding);
      require(verified.boundedMemory && verified.width == w && verified.height == h && verified.pixels == std::uint64_t(w) * h,
              "row AVIF readback is not bounded/native-size");
      require(got.width == w && got.height == h && got.format == AVIF_PIXEL_FORMAT_YUV444 &&
              got.transfer == reference.transfer && got.max_cll == reference.max_cll && got.max_pall == reference.max_pall &&
              got.exif && got.xmp, "row AVIF dropped precision, color, CLLI or metadata");
      int largest = 0; std::size_t differing = 0;
      for (std::size_t i = 0; i < got.rgb.size(); ++i) {
        const int d = std::abs(int(got.rgb[i]) - int(reference.rgb[i]));
        largest = std::max(largest, d); differing += d != 0;
      }
      require(largest <= 4 && differing * 50 <= got.rgb.size(), "row AVIF changed the native 10-bit codes");
      std::uint32_t iw = 0, ih = 0;
      require(!imageio_decode(bytes, encoding == HdrEncoding::AvifPq, iw, ih).empty() && iw == w && ih == h,
              "ImageIO cannot decode the disk-staged AVIF grid");
      // A malformed grid must not pass merely because all its cells decode.
      const auto file = read_heif(bytes);
      const auto& item = file.item(file.primary_item_id);
      auto malformed = bytes;
      malformed.at(item.extents.front().offset + 11) ^= 1;
      bool rejected = false;
      try { (void)verify_avif_pixels(malformed); } catch (const std::exception&) { rejected = true; }
      require(rejected, "AVIF grid crop/ispe mismatch passed verification");
      std::filesystem::remove(path);
    }
  }
  // Callback exceptions and cancellation must release both unlinked spools.
  EncodingRows base{65, 65, 3, [](unsigned, std::span<float>) { throw std::runtime_error("reader failed"); }};
  EncodingRows gain{65, 65, 1, [](unsigned, std::span<float>) {}};
  bool failed = false;
  try { write_avif_rows(base, gain, {}, 1, metadata, HdrEncoding::AvifPq, 90, path); }
  catch (const std::runtime_error&) { failed = true; }
  require(failed && !std::filesystem::exists(path), "failed AVIF reader created output");
}

// Test-only edits preserve all surrounding boxes and iloc extents, so failures
// below exercise the intended corruption rather than a broken outer container.
unsigned read_u32(const std::vector<std::uint8_t>& b, std::size_t p) {
  return (unsigned(b.at(p)) << 24) | (unsigned(b.at(p + 1)) << 16) |
         (unsigned(b.at(p + 2)) << 8) | b.at(p + 3);
}
// Cells decoded while the next one encodes: every cell reports its encode and
// its check, in order, and the file check then matches all of them. A sample
// the writer did not decode (a wrong digest) is decoded again, and a damaged
// one still fails.
void overlapped_cell_verification() {
  const auto path = test::temporary_directory() / "overlap.avif";
  const unsigned w = 2100, h = 1100;  // 3 x 2 cells
  const auto hdr = make_hdr(w, h);
  EncodingRows base{w, h, 3, [&](unsigned y, std::span<float> out) {
    std::copy_n(hdr.pixels.data() + std::size_t(y) * w * 3, out.size(), out.data());
  }};
  EncodingRows gain{w, h, 1, [](unsigned, std::span<float> out) { std::fill(out.begin(), out.end(), 0.f); }};
  GainMapMetadata map; map.alternate_headroom = {2, 1};
  PhotoMetadata metadata; metadata.orientation = 1;
  std::vector<std::pair<PackagePhase, std::uint32_t>> events;
  std::uint32_t total = 0, last_encoded = 0;
  const PackageProgress progress = [&](PackagePhase phase, std::uint32_t done, std::uint32_t of) {
    events.emplace_back(phase, done); total = of;
    if (phase == PackagePhase::EncodeCells) last_encoded = done;
    // Let the last pending decode finish after its snapshot was reported but
    // before drain starts: drain must continue from that snapshot, not done_.
    if (phase == PackagePhase::VerifyCells && last_encoded == of && done < of)
      std::this_thread::sleep_for(std::chrono::milliseconds(100));
  };
  AvifCellDigests decoded;
  {
    PackageProgressScope reporting(&progress);
    decoded = write_avif_rows(base, gain, map, 2, metadata, HdrEncoding::AvifPq, 90, path, true);
  }
  const auto layout = avif_row_grid_layout(w, h);
  const auto cells = layout.columns * layout.rows;
  require(cells == 6 && total == cells && decoded.samples.size() == cells, "overlapped AVIF lost cells");
  std::uint32_t encoded = 0, verified = 0;
  for (const auto& [phase, done] : events) {
    auto& counter = phase == PackagePhase::EncodeCells ? encoded : verified;
    require(done >= counter && done <= cells, "AVIF cell progress went backwards");
    counter = done;
    require(verified <= encoded, "a cell was verified before it was encoded");
  }
  require(encoded == cells && verified == cells, "AVIF cell progress did not finish");
  const auto bytes = read_binary_file(path);
  require(verify_avif_file(path, decoded).pixels == std::uint64_t(w) * h, "matched AVIF cells failed the file check");
  auto stale = decoded; stale.samples.front() ^= 1;
  require(verify_avif_pixels(bytes, &stale).width == w, "an unmatched AVIF cell was not decoded again");
  auto short_list = decoded; short_list.samples.pop_back();
  bool refused = false;
  try { (void)verify_avif_pixels(bytes, &short_list); } catch (const std::exception&) { refused = true; }
  require(refused, "a wrong decoded cell count passed");
  // Damage the first cell's coded payload: its digest no longer matches, so the
  // check decodes it and must fail as before.
  const auto file = read_heif(bytes);
  const auto first = file.targets(file.primary_item_id, "dimg").front();
  auto damaged = bytes;
  const auto& extent = file.item(first).extents.front();
  for (std::size_t i = extent.length / 2; i < extent.length; ++i) damaged.at(extent.offset + i) = 0xff;
  bool rejected = false;
  try { (void)verify_avif_pixels(damaged, &decoded); } catch (const std::exception&) { rejected = true; }
  require(rejected, "a damaged AVIF cell passed because its neighbours were decoded");
  // Cancelled after its first cell, the writer stops its verifier thread and returns.
  CancelToken cancel;
  unsigned callbacks_after_cancel = 0;
  const PackageProgress stop = [&](PackagePhase phase, std::uint32_t, std::uint32_t) {
    if (cancel.requested()) ++callbacks_after_cancel;
    if (phase == PackagePhase::EncodeCells) cancel.request();
  };
  bool cancelled = false;
  try {
    CancelScope scope(&cancel); PackageProgressScope reporting(&stop);
    (void)write_avif_rows(base, gain, map, 2, metadata, HdrEncoding::AvifPq, 90, path, true);
  } catch (const Cancelled&) { cancelled = true; }
  require(cancelled, "a cancelled AVIF writer did not stop");
  require(callbacks_after_cancel == 0, "AVIF progress was reported after cancellation");
  std::filesystem::remove(path);
}

void put_number(std::vector<std::uint8_t>& b, std::size_t p, unsigned value, unsigned count = 4) {
  for (unsigned i = 0; i < count; ++i) b.at(p + i) = std::uint8_t(value >> (8 * (count - 1 - i)));
}
std::size_t association(const std::vector<std::uint8_t>& bytes, unsigned id, unsigned index) {
  const auto file = read_heif(bytes);
  for (const auto& b : file.boxes) if (b.type == "ipma") {
    require(read_u32(bytes, b.offset + 8) == 1, "expected native 16-bit ipma");
    auto p = std::size_t(b.offset + 16);
    for (unsigned left = read_u32(bytes, b.offset + 12); left; --left) {
      const unsigned item = (unsigned(bytes.at(p)) << 8) | bytes.at(p + 1);
      const unsigned count = bytes.at(p + 2); p += 3;
      if (item == id) { require(index < count, "missing test association"); return p + index * 2; }
      p += count * 2;
    }
  }
  throw std::runtime_error("missing test ipma");
}
void replace_native_range(std::vector<std::uint8_t>& bytes, std::size_t start, std::size_t length,
                          const std::vector<std::uint8_t>& replacement) {
  const auto file = read_heif(bytes);
  const auto delta = std::int64_t(replacement.size()) - std::int64_t(length);
  for (const auto& b : file.boxes) {
    if (b.offset <= start && b.offset + b.size >= start + length)
      put_number(bytes, b.offset, unsigned(std::int64_t(b.size) + delta));
    if (b.type != "iloc") continue;
    require(read_u32(bytes, b.offset + 8) == 0 && bytes.at(b.offset + 12) == 0x44 &&
            bytes.at(b.offset + 13) == 0, "expected native iloc");
    const unsigned count = (unsigned(bytes.at(b.offset + 14)) << 8) | bytes.at(b.offset + 15);
    auto p = std::size_t(b.offset + 16);
    for (unsigned i = 0; i < count; ++i, p += 14) {
      require(bytes.at(p + 4) == 0 && bytes.at(p + 5) == 1, "expected one native extent");
      const auto offset = read_u32(bytes, p + 6), size = read_u32(bytes, p + 10);
      if (offset >= start + length) put_number(bytes, p + 6, unsigned(std::int64_t(offset) + delta));
      else if (offset == start && size == length) put_number(bytes, p + 10, unsigned(replacement.size()));
    }
  }
  bytes.erase(bytes.begin() + start, bytes.begin() + start + length);
  bytes.insert(bytes.begin() + start, replacement.begin(), replacement.end());
}
void rejects_avif(const std::vector<std::uint8_t>& bytes, const char* reason) {
  bool rejected = false;
  try { (void)verify_avif_pixels(bytes); } catch (const std::exception&) { rejected = true; }
  require(rejected, reason);
}
std::vector<std::uint8_t> sample_fixture(unsigned w, unsigned h, unsigned depth, avifPixelFormat format, int color_error = 0) {
  std::unique_ptr<avifImage, decltype(&avifImageDestroy)> image(avifImageCreate(w, h, depth, format), &avifImageDestroy);
  require(bool(image) && avifImageAllocatePlanes(image.get(), AVIF_PLANES_YUV) == AVIF_RESULT_OK, "allocate test AV1 planes");
  for (unsigned c = 0; c < 3; ++c) {
    const auto rows = c && format == AVIF_PIXEL_FORMAT_YUV420 ? (h + 1) / 2 : h;
    std::memset(image->yuvPlanes[c], 0, std::size_t(image->yuvRowBytes[c]) * rows);
  }
  image->yuvRange = color_error == 2 ? AVIF_RANGE_LIMITED : AVIF_RANGE_FULL;
  std::unique_ptr<avifEncoder, decltype(&avifEncoderDestroy)> encoder(avifEncoderCreate(), &avifEncoderDestroy);
  encoder->codecChoice = AVIF_CODEC_CHOICE_AOM; encoder->maxThreads = 1; encoder->quality = 100; encoder->speed = 6;
  if (color_error == 1) {
    // libavif normally clears OBU CICP to 2/2/2. Override it through AOM's
    // codec options, so repacking with a good colr cannot conceal Rec.709.
    for (const char* key : {"color-primaries", "transfer-characteristics", "matrix-coefficients"})
      require(avifEncoderSetCodecSpecificOption(encoder.get(), key, "bt709") == AVIF_RESULT_OK, "set test AV1 CICP");
  }
  avifRWData output = AVIF_DATA_EMPTY;
  struct Guard { avifRWData* output; ~Guard() { avifRWDataFree(output); } } guard{&output};
  require(avifEncoderWrite(encoder.get(), image.get(), &output) == AVIF_RESULT_OK, "encode test AV1 sample");
  const auto file = read_heif({output.data, output.size});
  return file.item_bytes(file.primary_item_id);
}
void original_container_and_codec_are_verified() {
  const auto path = test::temporary_directory() / "corruption.avif";
  EncodingRows base{65, 65, 3, [](unsigned, std::span<float> out) { std::fill(out.begin(), out.end(), .2f); }};
  EncodingRows gain{65, 65, 1, [](unsigned, std::span<float> out) { std::fill(out.begin(), out.end(), 0.f); }};
  const auto decoded = write_avif_rows(base, gain, {}, 1, {}, HdrEncoding::AvifPq, 100, path, true);
  const auto bytes = read_binary_file(path);
  std::filesystem::remove(path);
  const auto file = read_heif(bytes);
  const auto& primary = file.item(file.primary_item_id);
  const auto cell_id = file.targets(primary.id, "dimg").front();
  const auto prop_offset = [&](const char* type) {
    for (const auto& p : file.properties) if (p.type == type) return std::size_t(p.payload.data() - bytes.data());
    throw std::runtime_error("missing corruption fixture property");
  };
  const auto config = prop_offset("av1C");
  {
    auto corrupt = bytes;
    const auto& cell = file.item(cell_id);
    const auto ispe = file.properties.at(cell.properties.front().index - 1).payload;
    put_number(corrupt, std::size_t(ispe.data() - bytes.data()) + 4, 1088);
    bool rejected = false;
    try { (void)verify_avif_pixels(corrupt, &decoded); }
    catch (const std::exception& e) { rejected = std::string(e.what()) == "AVIF codec dimensions differ from ispe"; }
    require(rejected, "matched AVIF bytes bypassed verification of a changed ispe");
  }
  for (unsigned length : {0U, 3U, 5U, 4U * 1024 * 1024}) {
    auto corrupt = bytes;
    std::vector<std::uint8_t> payload(length, 0);
    std::copy_n(bytes.data() + config, std::min(4U, length), payload.data());
    replace_native_range(corrupt, config, 4, payload);
    rejects_avif(corrupt, "unbounded/short/extended av1C passed");
  }
  for (auto [byte, mask] : {std::pair{0U, 0x80U}, {0U, 1U}, {1U, 0x20U}, {2U, 0x40U},
                            {2U, 0x80U}, {2U, 0x20U}, {2U, 0x10U}, {2U, 8U}, {2U, 1U}, {3U, 0x80U}, {3U, 1U}}) {
    auto corrupt = bytes; corrupt.at(config + byte) ^= mask;
    rejects_avif(corrupt, "invalid av1C marker/version/profile/depth/chroma/reserved bits passed");
  }
  // Unknown essential on the grid, then on a cell only. Repacking a cell
  // discards its unknown property and would incorrectly pass the second case.
  for (bool cell_only : {false, true}) {
    auto corrupt = bytes;
    const auto clli = prop_offset("clli");
    std::copy_n("zzzz", 4, corrupt.begin() + clli - 4);
    if (cell_only) {
      put_number(corrupt, association(bytes, primary.id, 3), 4, 2); // nonessential on grid
      put_number(corrupt, association(bytes, cell_id, 1), 0x8004, 2); // unknown essential instead of cell pixi
    }
    rejects_avif(corrupt, "unknown original essential property passed");
  }
  {
    auto corrupt = bytes;
    const auto extent = primary.extents.front();
    std::vector<std::uint8_t> descriptor(13, 0);
    std::copy_n(bytes.data() + extent.offset, 12, descriptor.data());
    replace_native_range(corrupt, extent.offset, extent.length, descriptor);
    rejects_avif(corrupt, "grid descriptor exceeded 12-byte bound");
  }
  for (unsigned width : {129U, kAvifVerifyMaxCellSide + 1}) {
    auto corrupt = bytes;
    const auto& cell = file.item(cell_id);
    const auto ispe = file.properties.at(cell.properties.front().index - 1).payload;
    put_number(corrupt, std::size_t(ispe.data() - bytes.data()) + 4, width);
    rejects_avif(corrupt, "codec/ispe mismatch or over-budget cell was accepted");
  }
  for (auto [depth, format] : {std::pair{8U, AVIF_PIXEL_FORMAT_YUV444}, {10U, AVIF_PIXEL_FORMAT_YUV420}}) {
    auto corrupt = bytes;
    const auto extent = file.item(cell_id).extents.front();
    replace_native_range(corrupt, extent.offset, extent.length, sample_fixture(128, 128, depth, format));
    rejects_avif(corrupt, "actual codec depth/chroma mismatch passed nominal 10-bit 444 metadata");
  }
  for (int color_error : {1, 2}) {
    auto corrupt = bytes;
    const auto extent = file.item(cell_id).extents.front();
    replace_native_range(corrupt, extent.offset, extent.length, sample_fixture(128, 128, 10, AVIF_PIXEL_FORMAT_YUV444, color_error));
    rejects_avif(corrupt, "colr concealed incompatible codec CICP/range");
  }
  {
    auto corrupt = bytes; corrupt.at(prop_offset("colr") + 5) = 1;
    rejects_avif(corrupt, "non-Rec.2020 original color passed");
  }
  for (unsigned offset : {4U, 5U}) {
    auto corrupt = bytes; corrupt.at(prop_offset("pixi") + offset) = 1;
    rejects_avif(corrupt, "invalid original pixi channels/depth passed");
  }
  // The generic verifier's legacy bound is intentionally 4096, not 1024.
  PhotoRenditions rendition; rendition.hdr = make_hdr(8192, 64);
  const AvifGridLayout legacy{2, 1, 4096, 64};
  const auto old = encode_avif(rendition, {}, 100, HdrEncoding::AvifPq, &legacy);
  require(verify_avif_pixels(old).boundedMemory, "legacy 4096 cells/8-byte descriptor lost compatibility");
}

int spool_fd = -1, fail_command = 0, spool_collisions = 0, spool_attempts = 0, spool_create_error = 0;
bool saw_cloexec = false, saw_nocache = false;
std::string spool_name;
int capture_spool(const char* name, int flags, mode_t mode) {
  ++spool_attempts;
  saw_cloexec = (flags & O_CLOEXEC) != 0;
  require(flags == (O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC) && mode == 0600, "unsafe spool creation flags/mode");
  require(spool_name != name, "spool collision reused its UUID"); spool_name = name;
  if (spool_create_error) { errno = spool_create_error; return -1; }
  if (spool_collisions > 0) { --spool_collisions; errno = EEXIST; return -1; }
  spool_fd = open(name, flags, mode); return spool_fd;
}
int fail_unlink(const char*) { errno = EACCES; return -1; }
int configure_spool(int fd, int command, int value) {
  require(command == F_NOCACHE, "CLOEXEC must be set by open, not a later fcntl");
  if (command == F_NOCACHE && value == 1) saw_nocache = true;
  if (command == fail_command) { errno = EIO; return -1; }
  return fcntl(fd, command, value);
}
void spool_lifecycle() {
  const auto path = test::temporary_directory() / "spool.avif";
  try {
    internal::AvifSpool spool(path, capture_spool, fail_unlink);
    throw std::runtime_error("unlink failure was ignored");
  } catch (const std::system_error& e) { require(e.code().value() == EACCES, "lost unlink errno"); }
  struct stat state{};
  require(fcntl(spool_fd, F_GETFD) == -1 && errno == EBADF && stat(spool_name.c_str(), &state) == 0 && state.st_size == 0,
          "failed unlink left an open or populated spool");
  std::filesystem::remove(spool_name);
  for (int command : {0, F_NOCACHE}) {
    fail_command = command; saw_cloexec = saw_nocache = false;
    bool failed = false;
    try {
      internal::AvifSpool spool(path, capture_spool, unlink, configure_spool);
      require(command == 0 && (fcntl(spool_fd, F_GETFD) & FD_CLOEXEC) && saw_cloexec && saw_nocache,
              "spool missing close-on-exec/no-cache setup");
      require(fstat(spool_fd, &state) == 0 && state.st_nlink == 0, "spool is still named");
      const std::vector<std::uint8_t> expected{1, 2, 3}; std::vector<std::uint8_t> got(3);
      spool.write(expected); spool.seek(0); spool.read(got); require(got == expected, "spool round trip");
    } catch (const std::system_error& e) { require(e.code().value() == EIO, "lost fcntl errno"); failed = true; }
    require(failed == (command != 0) && !std::filesystem::exists(spool_name) &&
            fcntl(spool_fd, F_GETFD) == -1 && errno == EBADF, "spool setup/destruction leaked descriptor/name");
  }
  fail_command = 0;
  for (int collisions : {2, 8}) {
    spool_collisions = collisions; spool_attempts = 0; spool_fd = -1;
    bool failed = false;
    try { internal::AvifSpool spool(path, capture_spool); }
    catch (const std::system_error& e) { require(e.code().value() == EEXIST, "lost collision errno"); failed = true; }
    require(failed == (collisions == 8) && spool_attempts == (collisions == 8 ? 8 : 3) &&
            !std::filesystem::exists(spool_name), "spool collision retries are not bounded");
    if (!failed) require(fcntl(spool_fd, F_GETFD) == -1 && errno == EBADF, "retry leaked spool descriptor");
  }
  spool_create_error = ENOSPC; spool_attempts = 0;
  bool failed = false;
  try { internal::AvifSpool spool(path, capture_spool); }
  catch (const std::system_error& e) { require(e.code().value() == ENOSPC, "lost create errno"); failed = true; }
  require(failed && spool_attempts == 1, "non-collision open error was retried");
  spool_create_error = 0;
}

void bad_layouts_are_rejected() {
  PhotoRenditions renditions;
  renditions.hdr = make_hdr(200, 100);
  for (const AvifGridLayout bad : {AvifGridLayout{2, 1, 100, 0}, AvifGridLayout{2, 1, 50, 100},
                                   AvifGridLayout{2, 1, 201, 100}, AvifGridLayout{300, 1, 1, 100},
                                   AvifGridLayout{2, 2, 100, 40}}) {
    bool rejected = false;
    try { (void)encode_avif(renditions, {}, 80, HdrEncoding::AvifPq, &bad); }
    catch (const std::invalid_argument&) { rejected = true; }
    require(rejected, "an impossible grid layout was accepted");
  }
}

// Every engine entry point runs on a 512 KB stack; the grid path converts and
// codes cell by cell and must keep its frames small.
struct SmallStackJob {
  std::string failure;
};
void* small_stack_grid(void* argument) {
  auto& job = *static_cast<SmallStackJob*>(argument);
  try {
    PhotoRenditions renditions;
    renditions.hdr = make_hdr(300, 200);
    renditions.stats.headroom_stops = 2.0F;
    const AvifGridLayout layout{3, 2, 100, 100};
    for (const auto encoding : {HdrEncoding::AvifPq, HdrEncoding::AvifHlg}) {
      const auto bytes = encode_avif(renditions, {}, 85, encoding, &layout);
      verify_avif_decodable(bytes);
      require(libavif_decode(bytes).width == 300, "grid decoded to the wrong width");
      const auto path = test::temporary_directory() / "small-stack-rows.avif";
      EncodingRows base{300, 200, 3, [&](unsigned y, std::span<float> out) {
        std::copy_n(renditions.hdr.pixels.data() + std::size_t(y) * 300 * 3, out.size(), out.data());
      }};
      EncodingRows gain{300, 200, 1, [](unsigned, std::span<float> out) { std::fill(out.begin(), out.end(), 0.f); }};
      write_avif_rows(base, gain, {}, 1, {}, encoding, 85, path);
      require(verify_encoded_file(path, encoding).boundedMemory, "row AVIF on small stack is unbounded");
      std::filesystem::remove(path);
    }
  } catch (const std::exception& e) {
    job.failure = e.what();
  }
  return nullptr;
}
void grid_on_small_stack() {
  SmallStackJob job;
  pthread_attr_t attributes;
  require(pthread_attr_init(&attributes) == 0 && pthread_attr_setstacksize(&attributes, 512 * 1024) == 0,
          "512 KB stack unavailable");
  pthread_t worker;
  require(pthread_create(&worker, &attributes, small_stack_grid, &job) == 0, "512 KB thread creation failed");
  pthread_attr_destroy(&attributes);
  require(pthread_join(worker, nullptr) == 0, "512 KB thread join failed");
  require(job.failure.empty(), "AVIF grid on a 512 KB stack: " + job.failure);
}

// The automatic choice end to end: a 132 MP canvas that libaom cannot code as
// one frame (it failed with "Failed to allocate lag buffers") comes out as a
// grid. About 2 GB and 15 s, so opt in with HYPERDR_AVIF_GRID_LARGE=1.
void large_canvas_default_path() {
  if (!std::getenv("HYPERDR_AVIF_GRID_LARGE")) return;
  constexpr std::uint32_t w = 12000, h = 11000;
  require(avif_grid_layout(w, h).is_grid(), "132 MP canvas should be a grid");
  PhotoRenditions renditions;
  renditions.hdr = make_hdr(w, h);
  renditions.stats.headroom_stops = 2.0F;
  const auto bytes = encode_avif(renditions, {}, 60, HdrEncoding::AvifPq);
  verify_avif_decodable(bytes);
  std::uint32_t iw = 0, ih = 0;
  const auto pixels = imageio_decode(bytes, true, iw, ih);
  require(iw == w && ih == h && !pixels.empty(), "ImageIO cannot decode the large grid");
  std::cout << "large canvas grid: " << bytes.size() << " bytes\n";
}
}  // namespace

int main() try {
  layout_rule();
  row_layout_rule();
  grid_matches_single_item();
  pull_rows_match_native_codes();
  overlapped_cell_verification();
  original_container_and_codec_are_verified();
  spool_lifecycle();
  bad_layouts_are_rejected();
  grid_on_small_stack();
  large_canvas_default_path();
  std::cout << "avif_grid_test passed\n";
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}

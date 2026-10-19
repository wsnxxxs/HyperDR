// E8: canvases libaom cannot hold as one frame are written as AVIF grids.
// Covers the layout rule at its boundaries, a cell-for-cell comparison with the
// single-item encoding (libavif and ImageIO both decode it), and the guard that
// keeps ordinary canvases byte-for-byte on the single-item path.
#include "hyperdr/codec/avif_grid.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "internal/decode_bytes.hpp"

#include <avif/avif.h>
#include <pthread.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>

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
  require(story.columns == 3 && story.rows == 5 && story.cell_width == 3400 && story.cell_height == 3627,
          "61 MP story layout changed");
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
  grid_matches_single_item();
  bad_layouts_are_rejected();
  grid_on_small_stack();
  large_canvas_default_path();
  std::cout << "avif_grid_test passed\n";
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}

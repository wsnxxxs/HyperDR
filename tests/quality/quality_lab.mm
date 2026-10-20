#include "hevc/hevc.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/transfer.hpp"
#include "internal/heif_decoder.hpp"
#include "internal/icc_profiles.hpp"
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iostream>
using namespace hyperdr;
namespace h = hyperdr::codec::hevc;
static void require(bool v, const char *s) {
  if (!v)
    throw std::runtime_error(s);
}
static std::size_t payload(const HeifFile &, const HeifImagePlan &p) {
  std::size_t n = 0;
  for (const auto &t : p.tiles)
    for (const auto &e : t.extents)
      n += e.length;
  return n;
}
static void inspect(const std::filesystem::path &path) {
  auto b = read_binary_file(path);
  auto f = read_heif(b);
  auto p = f.resolve_image(0, HeifCanvas::Tiled);
  auto g = f.resolve_gain_map(HeifCanvas::Tiled);
  std::cout << json::Writer()
                   .begin_object()
                   .member("bytes", b.size())
                   .member("base_bytes", payload(f, p))
                   .member("gain_bytes", g ? payload(f, g->gain) : 0)
                   .member("width", p.width)
                   .member("height", p.height)
                   .member("base_tile", p.tile_width)
                   .member("gain_tile", g ? g->gain.tile_width : 0)
                   .member("depth", p.config.bit_depth)
                   .member("profile", p.config.profile)
                   .end_object()
                   .take()
            << '\n';
}

#include "hyperdr/app/package.hpp"
#include <iomanip>
struct Scene {
  FloatImage base, gain, hdr;
  bool frame = false;
};
static Scene scene(const std::string &name, unsigned w, unsigned height,
                   const std::string &input) {
  Scene s{FloatImage(w, height, 3), FloatImage(w, height, 1),
          FloatImage(w, height, 3), name == "frame"};
  if (!input.empty()) {
    NSURL *url =
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:input.c_str()]];
    auto source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    require(source, "photo source");
    auto image = CGImageSourceCreateThumbnailAtIndex(
        source, 0, (__bridge CFDictionaryRef) @{
          (id)kCGImageSourceCreateThumbnailFromImageAlways : @YES,
          (id)kCGImageSourceThumbnailMaxPixelSize : @(std::max(w, height)),
          (id)kCGImageSourceCreateThumbnailWithTransform : @YES
        });
    CFRelease(source);
    require(image, "photo thumbnail");
    CIImage *ci = [CIImage imageWithCGImage:image];
    CGImageRelease(image);
    const auto extent = ci.extent;
    const double scale = std::max(double(w) / extent.size.width,
                                  double(height) / extent.size.height);
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    ci = [ci
        imageByCroppingToRect:CGRectMake((ci.extent.size.width - w) / 2,
                                         (ci.extent.size.height - height) / 2,
                                         w, height)];
    ci = [ci
        imageByApplyingTransform:CGAffineTransformMakeTranslation(
                                     -ci.extent.origin.x, -ci.extent.origin.y)];
    CIContext *ctx = [CIContext contextWithOptions:@{
      kCIContextCacheIntermediates : @NO
    }];
    auto space =
        CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    std::vector<float> rgba(std::size_t(w) * height * 4);
    [ctx render:ci
          toBitmap:rgba.data()
          rowBytes:w * 16
            bounds:CGRectMake(0, 0, w, height)
            format:kCIFormatRGBAf
        colorSpace:space];
    CGColorSpaceRelease(space);
    for (std::size_t i = 0; i < s.base.pixels.size() / 3; ++i)
      for (unsigned c = 0; c < 3; ++c)
        s.base.pixels[i * 3 + c] = std::clamp(rgba[i * 4 + c], 0.f, 1.f);
  }
  for (unsigned y = 0; y < height; ++y)
    for (unsigned x = 0; x < w; ++x) {
      const auto i = std::size_t(y) * w + x;
      const float u = (x + .5f) / w, v = (y + .5f) / height;
      const float detail = .025f * std::cos(v * 80 * float(M_PI)) *
                           std::sin(u * 90 * float(M_PI));
      if (input.empty()) {
        const std::array<float, 3> rgb{
            .03f + .8f * u + detail, .08f + .65f * (1 - u) + detail,
            .05f + .6f * std::sin(v * float(M_PI)) + detail};
        for (unsigned c = 0; c < 3; ++c)
          s.base.pixels[i * 3 + c] = std::clamp(rgb[c], .005f, .95f);
        if (name == "ramp")
          for (unsigned c = 0; c < 3; ++c)
            s.base.pixels[i * 3 + c] = .005F + .9F * u;
        if (name == "edges") {
          const std::array<std::array<float, 3>, 4> colors{{{.65f, .38f, .25f},
                                                            {.05f, .75f, .15f},
                                                            {.9f, .03f, .04f},
                                                            {.03f, .1f, .9f}}};
          for (unsigned c = 0; c < 3; ++c)
            s.base.pixels[i * 3 + c] =
                colors[(x / (w / 4)) % 4][c] * (.4f + .6f * v);
        }
      }
      s.gain.pixels[i] = 2 * u;
      if (s.frame && (x < 32 || y < 32 || x >= w - 32 || y >= height - 32)) {
        s.gain.pixels[i] = 0;
        for (unsigned c = 0; c < 3; ++c)
          s.base.pixels[i * 3 + c] = .8f;
      }
      for (unsigned c = 0; c < 3; ++c)
        s.hdr.pixels[i * 3 + c] =
            s.base.pixels[i * 3 + c] * std::exp2(s.gain.pixels[i]);
    }
  return s;
}
static void imageio(const Scene &s, const std::string &format, int depth, int q,
                    const std::filesystem::path &file, bool tiled) {
  bool hdr = format == "pq" || format == "hlg", gain = format == "adaptive";
  unsigned bits = hdr || depth == 10 ? 16 : 8;
  std::vector<std::uint8_t> pixels(std::size_t(s.base.width) * s.base.height *
                                   4 * (bits / 8));
  for (std::size_t i = 0; i < s.base.pixels.size() / 3; ++i) {
    std::array<float, 3> rgb;
    if (hdr) {
      rgb = p3_to_rec2020(s.hdr.pixels[i * 3], s.hdr.pixels[i * 3 + 1],
                          s.hdr.pixels[i * 3 + 2]);
      rgb = format == "pq"
                ? std::array{pq_oetf(rgb[0]), pq_oetf(rgb[1]), pq_oetf(rgb[2])}
                : hlg_encode(rgb);
    } else
      for (unsigned c = 0; c < 3; ++c)
        rgb[c] = srgb_oetf(s.base.pixels[i * 3 + c]);
    for (unsigned c = 0; c < 4; ++c) {
      const float v = c == 3 ? 1.f : std::clamp(rgb[c], 0.f, 1.f);
      if (bits == 8)
        pixels[i * 4 + c] = std::uint8_t(std::lround(v * 255));
      else
        reinterpret_cast<std::uint16_t *>(pixels.data())[i * 4 + c] =
            std::uint16_t(std::lround(v * 65535));
    }
  }
  auto space = CGColorSpaceCreateWithName(
      hdr ? (format == "pq" ? kCGColorSpaceITUR_2100_PQ
                            : kCGColorSpaceITUR_2100_HLG)
          : kCGColorSpaceDisplayP3);
  auto data = CFDataCreate(nullptr, pixels.data(), pixels.size());
  auto provider = CGDataProviderCreateWithCFData(data);
  auto image = CGImageCreate(
      s.base.width, s.base.height, bits, bits * 4,
      s.base.width * 4 * (bits / 8), space,
      kCGImageAlphaNoneSkipLast | (bits == 16 ? kCGBitmapByteOrder16Little : 0),
      provider, nullptr, false, kCGRenderingIntentDefault);
  require(image, "CGImage pixels");
  NSURL *url =
      [NSURL fileURLWithPath:[NSString stringWithUTF8String:file.c_str()]];
  auto destination = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, CFSTR("public.heic"), 1, nullptr);
  require(destination, "ImageIO HEIC writer");
  NSMutableDictionary *properties = [@{
    (id)kCGImageDestinationLossyCompressionQuality : @(q / 100.),
    (id)kCGImagePropertyOrientation : @1
  } mutableCopy];
  if (tiled)
    properties[(id)kCGImagePropertyTIFFDictionary] = @{
      (id)kCGImagePropertyTIFFTileWidth : @512,
      (id)kCGImagePropertyTIFFTileLength : @512
    };
  CGImageDestinationAddImage(destination, image,
                             (__bridge CFDictionaryRef)properties);
  if (gain) {
    std::vector<std::uint8_t> codes(s.gain.pixels.size());
    for (std::size_t i = 0; i < codes.size(); ++i)
      codes[i] = std::uint8_t(std::lround(s.gain.pixels[i] / 2 * 255));
    NSString *xml =
        @"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF "
        @"xmlns:rdf=\"http://www.w3.org/1999/02/"
        @"22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" "
        @"xmlns:HDRToneMap=\"http://ns.apple.com/HDRToneMap/1.0/"
        @"\"><HDRToneMap:Version>1</"
        @"HDRToneMap:Version><HDRToneMap:BaseColorIsWorkingColor>True</"
        @"HDRToneMap:BaseColorIsWorkingColor><HDRToneMap:BaseHeadroom>0</"
        @"HDRToneMap:BaseHeadroom><HDRToneMap:AlternateHeadroom>2</"
        @"HDRToneMap:AlternateHeadroom><HDRToneMap:ChannelMetadata><rdf:Seq><"
        @"rdf:li "
        @"rdf:parseType=\"Resource\"><HDRToneMap:GainMapMin>0</"
        @"HDRToneMap:GainMapMin><HDRToneMap:GainMapMax>2</"
        @"HDRToneMap:GainMapMax><HDRToneMap:Gamma>1</"
        @"HDRToneMap:Gamma><HDRToneMap:BaseOffset>0</"
        @"HDRToneMap:BaseOffset><HDRToneMap:AlternateOffset>0</"
        @"HDRToneMap:AlternateOffset></rdf:li></rdf:Seq></"
        @"HDRToneMap:ChannelMetadata></rdf:Description></rdf:RDF></x:xmpmeta>";
    auto metadata = CGImageMetadataCreateFromXMPData(
        (__bridge CFDataRef)[xml dataUsingEncoding:NSUTF8StringEncoding]);
    require(metadata, "gain XMP");
    NSDictionary *auxiliary = @{
      (id)kCGImageAuxiliaryDataInfoData : [NSData dataWithBytes:codes.data()
                                                         length:codes.size()],
      (id)kCGImageAuxiliaryDataInfoDataDescription : @{
        @"Width" : @(s.base.width),
        @"Height" : @(s.base.height),
        @"BytesPerRow" : @(s.base.width),
        @"PixelFormat" : @(kCVPixelFormatType_OneComponent8)
      },
      (id)kCGImageAuxiliaryDataInfoMetadata : (__bridge id)metadata
    };
    CGImageDestinationAddAuxiliaryDataInfo(destination,
                                           kCGImageAuxiliaryDataTypeISOGainMap,
                                           (__bridge CFDictionaryRef)auxiliary);
    CFRelease(metadata);
  }
  require(CGImageDestinationFinalize(destination), "ImageIO finalize");
  CFRelease(destination);
  CGImageRelease(image);
  CGDataProviderRelease(provider);
  CFRelease(data);
  CGColorSpaceRelease(space);
}
static std::vector<std::uint8_t> native(const Scene &s,
                                        const std::string &format, int depth,
                                        int q, bool dither) {
  const auto grid = h::tile_grid(s.base.width, s.base.height);
  const bool hdr = format == "pq" || format == "hlg";
  h::EncodeParams params{
      q, depth == 10,
      hdr ? h::ColorDescription{9, format == "pq" ? 16 : 18, 9}
          : h::ColorDescription{12, 13, 1}};
  auto base = h::encode(
      grid.count(),
      [&](std::size_t i, h::YuvTile &tile) {
        h::rgb_tile(
            grid, i,
            [&](unsigned y, unsigned x, unsigned count, float *out) {
              for (unsigned n = 0; n < count; ++n) {
                auto off = (std::size_t(y) * s.base.width + x + n) * 3;
                std::array<float, 3> rgb;
                if (hdr) {
                  rgb = p3_to_rec2020(s.hdr.pixels[off], s.hdr.pixels[off + 1],
                                      s.hdr.pixels[off + 2]);
                  rgb = format == "pq"
                            ? std::array{pq_oetf(rgb[0]), pq_oetf(rgb[1]),
                                         pq_oetf(rgb[2])}
                            : hlg_encode(rgb);
                } else
                  for (unsigned c = 0; c < 3; ++c)
                    rgb[c] = srgb_oetf(s.base.pixels[off + c]);
                std::copy(rgb.begin(), rgb.end(), out + n * 3);
              }
            },
            hdr ? 9 : 1, dither, tile);
      },
      params);
  const auto icc = codec::display_p3_profile();
  HeifEncodedImage primary{
      base,
      s.base.width,
      s.base.height,
      hdr ? HeifNclx{9, std::uint16_t(format == "pq" ? 16 : 18), 9, true}
          : HeifNclx{},
      hdr ? std::optional<HeifContentLight>{{1000, 203}} : std::nullopt,
      hdr ? std::span<const std::uint8_t>{}
          : std::span<const std::uint8_t>{icc}};
  if (format != "adaptive")
    return write_heif(primary);
  params = {95, false, {2, 2, 1}};
  auto gain = h::encode(
      grid.count(),
      [&](std::size_t i, h::YuvTile &tile) {
        h::luma_tile(
            grid, i,
            [&](unsigned y, unsigned x, unsigned count, float *out) {
              for (unsigned n = 0; n < count; ++n)
                out[n] = std::round(s.gain.at(x + n, y, 0) / 2 * 255) / 255;
            },
            tile);
      },
      params);
  HeifEncodedImage g{gain, s.base.width, s.base.height, {2, 2, 1, true}, {},
                     {}};
  HeifWriteOptions opts;
  GainMapMetadata m;
  m.gain_max = {2, 1};
  m.alternate_headroom = {2, 1};
  opts.gain_metadata = m;
  return write_heif(primary, &g, opts);
}
static double ypsnr(const FloatImage &a, const FloatImage &b) {
  require(a.width == b.width && a.height == b.height, "metric dimensions");
  double error = 0;
  for (std::size_t i = 0; i < a.pixels.size(); i += 3) {
    double d = 0;
    const double weights[] = {.2126, .7152, .0722};
    for (unsigned c = 0; c < 3; ++c)
      d += weights[c] * (srgb_oetf(std::max(0.f, a.pixels[i + c])) -
                         srgb_oetf(std::max(0.f, b.pixels[i + c])));
    error += d * d;
  }
  return 10 * std::log10(double(a.width) * a.height / std::max(error, 1e-30));
}
static FloatImage system_decode(const std::filesystem::path &path, bool hdr) {
  NSURL *url =
      [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  auto source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
  require(source, "system decode source");
  NSDictionary *options = @{
    (id)kCGImageSourceDecodeRequest :
        (id)(hdr ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR)
  };
  auto image = CGImageSourceCreateImageAtIndex(
      source, 0, (__bridge CFDictionaryRef)options);
  CFRelease(source);
  require(image, "system decode image");
  FloatImage out(unsigned(CGImageGetWidth(image)),
                 unsigned(CGImageGetHeight(image)), 3);
  std::vector<float> rgba(std::size_t(out.width) * out.height * 4);
  CIContext *context = [CIContext contextWithOptions:@{
    kCIContextCacheIntermediates : @NO
  }];
  auto space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
  [context render:[CIImage imageWithCGImage:image]
         toBitmap:rgba.data()
         rowBytes:out.width * 16
           bounds:CGRectMake(0, 0, out.width, out.height)
           format:kCIFormatRGBAf
       colorSpace:space];
  CGColorSpaceRelease(space);
  CGImageRelease(image);
  for (std::size_t i = 0; i < rgba.size() / 4; ++i)
    for (unsigned c = 0; c < 3; ++c)
      out.pixels[i * 3 + c] = rgba[i * 4 + c];
  return out;
}
static void run(int argc, char **argv) {
  require(argc >= 10, "quality_lab run WRITER FORMAT DEPTH QUALITY SCENE WIDTH "
                      "HEIGHT OUTPUT [PHOTO]");
  const std::string writer = argv[2], format = argv[3], name = argv[6];
  const int depth = atoi(argv[4]), q = atoi(argv[5]);
  auto s = scene(name, unsigned(atoi(argv[7])), unsigned(atoi(argv[8])),
                 argc > 10 ? argv[10] : "");
  const std::filesystem::path file = argv[9];
  std::string package_report;
  auto start = std::chrono::steady_clock::now();
  if (writer == "imageio" || writer == "imageio-auto")
    imageio(s, format, depth, q, file, writer == "imageio");
  else if (writer == "package") {
    PackagePlane b{
        s.base.pixels.data(), 0, s.base.pixels.size() * 4, s.base.width,
        s.base.height,        3};
    PackageGain g;
    g.plane = {s.gain.pixels.data(), 0, s.gain.pixels.size() * 4, s.gain.width,
               s.gain.height,        1};
    g.alternate_headroom = 2;
    PackageRequest r;
    r.output = file;
    r.sdr = &b;
    r.gain = &g;
    const auto encoding = hdr_encoding_from_name(format);
    require(encoding.has_value(), "unknown package format");
    r.encoding = *encoding;
    r.quality = q;
    r.depth = format == "adaptive" ? depth : 8;
    r.verify = false;
    r.overwrite = true;
    r.presentation_frame = s.frame;
    if (s.frame)
      r.frame_photo = FrameRect{32, 32, s.base.width - 64, s.base.height - 64};
    package_report = package_image(r);
  } else
    write_binary_file_atomic(file,
                             native(s, format, depth, q,
                                    writer != "native-nearest"),
                             true);
  const auto seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
          .count();
  auto bytes = read_binary_file(file);
  auto f = read_heif(bytes);
  auto plan = f.resolve_image(0, HeifCanvas::Tiled);
  auto gp = f.resolve_gain_map(HeifCanvas::Tiled);
  require(plan.width == s.base.width && plan.height == s.base.height,
          "semantic dimensions");
  require(plan.config.bit_depth == unsigned(depth), "semantic bit depth");
  const auto exif = f.exif();
  const auto orientation = read_exif_orientation(exif.data(), exif.size());
  require(!orientation || *orientation == 1, "semantic orientation");
  for (const auto &transform : plan.transforms)
    require(transform.type == "clap" || transform.value == 0,
            "semantic transform");
  require(bool(gp) == (format == "adaptive"), "semantic gain presence");
  const auto color = plan.config.vui_color;
  require(color.has_value(), "semantic VUI color missing");
  const bool color_matches =
      color->primaries == (format == "pq" || format == "hlg" ? 9 : 12) &&
      color->transfer == (format == "pq"    ? 16
                          : format == "hlg" ? 18
                                            : 13);
  if (writer != "imageio" && writer != "imageio-auto")
    require(color_matches, "semantic transfer/primaries");
  if (gp) {
    require(gp->metadata.has_value() && gp->gain.width == plan.width &&
                gp->gain.height == plan.height,
            "semantic gain geometry");
    const auto &m = *gp->metadata;
    require(gain_map_channel_count(m) == 1, "semantic gain channels");
    const auto c = gain_map_channel(m, 0);
    require(std::abs(rational_value(m.base_headroom)) <= 1e-6 &&
                std::abs(rational_value(m.alternate_headroom) - 2) <= 1e-6,
            "semantic headroom");
    require(rational_value(c.base_offset) == 0 &&
                rational_value(c.alternate_offset) == 0,
            "semantic offsets");
    if (!package_report.empty()) {
      const auto report = json::parse(package_report);
      const auto *expected = report.find("gain");
      require(expected, "gain report missing");
      for (const auto &[name, value] :
           std::array<std::pair<const char *, double>, 3>{
               {{"gainMin", rational_value(c.gain_min)},
                {"gainMax", rational_value(c.gain_max)},
                {"gamma", rational_value(c.gamma)}}})
        require(expected->find(name) &&
                    std::abs(expected->find(name)->number() - value) <= 1e-6,
                "semantic codebook");
    }
  }
  auto decoded = codec::decode_heic_bytes(bytes, RawDecodeOptions{});
  const auto &base =
      decoded.authored_sdr ? *decoded.authored_sdr : decoded.linear_p3;
  json::Writer output;
  output.begin_object()
      .member("writer", writer)
      .member("format", format)
      .member("requested_depth", depth)
      .member("depth", plan.config.bit_depth)
      .member("quality", q)
      .member("scene", name)
      .member("bytes", bytes.size())
      .member("base_bytes", payload(f, plan))
      .member("gain_bytes", gp ? payload(f, gp->gain) : 0)
      .member("tile", plan.tile_width)
      .member("profile", plan.config.profile)
      .member("primaries", color->primaries)
      .member("transfer", color->transfer)
      .member("color_matches", color_matches)
      .member("seconds", seconds)
      .member("width", plan.width)
      .member("height", plan.height);
  if (format == "adaptive" || format == "sdr")
    output.member("y_psnr_db", ypsnr(s.base, base))
        .member("system_y_psnr_db", ypsnr(s.base, system_decode(file, false)));
  if (name == "ramp") {
    double max_step = 0;
    std::uint64_t flat = 0, samples = 0;
    for (unsigned y = 0; y < base.height; ++y)
      for (unsigned x = 1; x < base.width; ++x) {
        const auto delta = std::abs(srgb_oetf(base.at(x, y, 0)) -
                                    srgb_oetf(base.at(x - 1, y, 0)));
        max_step = std::max(max_step, double(delta));
        flat += delta < 1e-6F;
        ++samples;
      }
    output.member("ramp_max_code_step", max_step)
        .member("ramp_flat_fraction", double(flat) / samples);
  }
  if (format != "sdr") {
    const auto metric = measure_hdr_fidelity(s.hdr, decoded.linear_p3);
    output.member("psnr_pq_db", metric.psnr_pq_db)
        .member("itp_mean", metric.delta_e_itp_mean)
        .member("itp_p50", metric.delta_e_itp_p50)
        .member("itp_p95", metric.delta_e_itp_p95)
        .member("itp_p99", metric.delta_e_itp_p99)
        .member("itp_p999", metric.delta_e_itp_p999)
        .member("reference_peak", metric.reference_peak)
        .member("candidate_peak", metric.candidate_peak)
        .member("reference_mean", metric.reference_mean)
        .member("candidate_mean", metric.candidate_mean);
  }
  if (gp) {
    auto parts = codec::decode_heif_adaptive_parts(f, *gp);
    FloatImage mid_reference = s.base;
    for (std::size_t i = 0; i < s.gain.pixels.size(); ++i)
      for (unsigned c = 0; c < 3; ++c)
        mid_reference.pixels[i * 3 + c] *= std::exp2(.5F * s.gain.pixels[i]);
    const auto mid =
        reconstruct_gain_map(base, parts.gain, parts.metadata, 1.F);
    output.member("mid_psnr_pq_db",
                  measure_hdr_fidelity(mid_reference, mid).psnr_pq_db);
    double error = 0;
    float mat = 0;
    for (unsigned y = 0; y < s.base.height; ++y)
      for (unsigned x = 0; x < s.base.width; ++x) {
        auto c = gain_map_channel(parts.metadata, 0);
        float v = std::clamp(parts.gain.at(x, y, 0), 0.f, 1.f);
        float g =
            std::lerp(rational_value(c.gain_min), rational_value(c.gain_max),
                      std::pow(v, 1.f / rational_value(c.gamma)));
        const float d = g - s.gain.at(x, y, 0);
        error += d * d;
        if (s.frame && (x < 24 || y < 24 || x >= s.base.width - 24 ||
                        y >= s.base.height - 24))
          mat = std::max(mat, std::abs(g));
      }
    output
        .member("gain_psnr_db", 10 * std::log10(4. * s.gain.pixels.size() /
                                                std::max(error, 1e-30)))
        .member("mat_max_stops", mat)
        .member("headroom", rational_value(parts.metadata.alternate_headroom));
  }
  output.end_object();
  std::cout << output.take() << '\n';
}
int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      if (argc == 3 && std::string(argv[1]) == "inspect")
        inspect(argv[2]);
      else
        run(argc, argv);
      return 0;
    } catch (const std::exception &e) {
      std::cerr << e.what() << '\n';
      return 1;
    }
  }
}

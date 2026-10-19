// Shared Apple RAW pipeline for the CLI, C ABI and application.
#include "internal/raw.hpp"
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <cmath>
#include <memory>
#include <mutex>
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "internal/budget.hpp"
#include "internal/metadata.hpp"
#include "internal/raw_ciraw.hpp"

namespace hyperdr {
namespace {
struct Identity {
  std::string path;
  dev_t device{};
  ino_t inode{};
  off_t size{};
  timespec modified{}, changed{};
  bool operator==(const Identity& b) const {
    return path == b.path && device == b.device && inode == b.inode && size == b.size &&
           modified.tv_sec == b.modified.tv_sec && modified.tv_nsec == b.modified.tv_nsec &&
           changed.tv_sec == b.changed.tv_sec && changed.tv_nsec == b.changed.tv_nsec;
  }
};
Identity readable_identity(const std::filesystem::path& path) {
  const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) throw SourceUnreadable("cannot open RAW source: " + path_utf8(path));
  struct stat s{};
  const int status = fstat(fd, &s);
  close(fd);
  if (status || !S_ISREG(s.st_mode))
    throw SourceUnreadable("RAW source is not a readable regular file");
  return {std::filesystem::weakly_canonical(path).string(),
          s.st_dev,
          s.st_ino,
          s.st_size,
          s.st_mtimespec,
          s.st_ctimespec};
}
std::string text(NSString* value) {
  return value ? std::string(value.UTF8String ?: "") : std::string{};
}
struct CachedRaw {
  Identity identity;
  std::string source_sha256;
  __strong CIRAWFilter* filter;
  RawProcessing processing;
  std::uint32_t width{}, height{};
};
std::mutex cache_mutex, override_mutex;
std::unique_ptr<CachedRaw> cached;
std::string build_override;
std::uint64_t open_count{}, render_count{};
std::function<void()> open_hook;
std::function<void(unsigned, unsigned)> block_hook;
std::unique_lock<std::mutex> cancellable_cache_lock() {
  std::unique_lock lock(cache_mutex, std::defer_lock);
  while (!lock.try_lock()) {
    check_cancelled();
    usleep(1000);
  }
  check_cancelled();
  return lock;
}

// Keep the complete neutral recipe in one place. The system default decoder,
// as-shot white balance and highlight recovery are deliberately left alone.
void neutral_settings(CIRAWFilter* f) {
  f.boostAmount = 0;
  f.boostShadowAmount = 0;
  f.exposure = 0;
  f.baselineExposure = 0;
  f.extendedDynamicRangeAmount = 1;
  f.gamutMappingEnabled = YES;
  f.draftModeEnabled = NO;
  if (f.isContrastSupported) f.contrastAmount = 0;
  if (f.isSharpnessSupported) f.sharpnessAmount = 0;
  if (f.isDetailSupported) f.detailAmount = 0;
  if (f.isLocalToneMapSupported) f.localToneMapAmount = 0;
  if (f.isLuminanceNoiseReductionSupported) f.luminanceNoiseReductionAmount = 0;
  if (f.isColorNoiseReductionSupported) f.colorNoiseReductionAmount = 0;
  if (f.isMoireReductionSupported) f.moireReductionAmount = 0;
  if (f.isDespeckleSupported) f.despeckleAmount = 0;
}
RawUnsupported unsupported(const std::filesystem::path& path) {
  const auto prefix=read_binary_prefix(path,64*1024);
  const bool dng=has_dng_version_ifd0(prefix.data(),prefix.size());
  CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())],nullptr);
  NSDictionary* properties=source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,nullptr)) : nil;
  if(source)CFRelease(source);
  NSDictionary* tiff=properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary];
  const auto clean=[](id value)->NSString* {
    if(![value isKindOfClass:[NSString class]])return @"";
    NSString* withoutControls=[[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@""];
    return [withoutControls stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  };
  NSString* make=clean(tiff[(__bridge NSString*)kCGImagePropertyTIFFMake]);
  NSString* model=clean(tiff[(__bridge NSString*)kCGImagePropertyTIFFModel]);
  if(!model.length && dng) {
    NSDictionary* tags=properties[(__bridge NSString*)kCGImagePropertyDNGDictionary];
    model=clean(tags[(__bridge NSString*)kCGImagePropertyDNGUniqueCameraModel]);
  }
  if(model.length && make.length && [model rangeOfString:make options:NSCaseInsensitiveSearch|NSAnchoredSearch].location!=0)
    model=[NSString stringWithFormat:@"%@ %@",make,model];
  else if(!model.length)model=make;
  auto camera=text(model);
  if(camera.size()>128) {
    std::size_t end=128;
    while(end && (static_cast<unsigned char>(camera[end])&0xc0)==0x80)--end;
    camera.resize(end);
  }
  return RawUnsupported(dng ? "dng" : "camera",std::move(camera));
}
CachedRaw& opened(const std::filesystem::path& path, const std::string& source_sha256 = {}) {
  check_cancelled();
  const auto identity = readable_identity(path);
  if (cached && cached->identity == identity &&
      (source_sha256.empty() || cached->source_sha256.empty() ||
       cached->source_sha256 == source_sha256)) {
    if (!source_sha256.empty()) cached->source_sha256 = source_sha256;
    cached->processing.os_build=raw_os_build();
    return *cached;
  }
  cached.reset();  // Never hold the previous photo's GPU allocations while opening a new one.
  CIRAWFilter* filter = [CIRAWFilter filterWithImageURL:[NSURL fileURLWithPath:@(path.c_str())]];
  ++open_count;
  if (open_hook) open_hook();
  check_cancelled();
  if (!filter || filter.nativeSize.width <= 0 || filter.nativeSize.height <= 0)
    throw unsupported(path);
  const float baseline = filter.baselineExposure;
  neutral_settings(filter);
  filter.scaleFactor = 1;
  CIImage* image = filter.outputImage;
  if (!image || CGRectIsEmpty(image.extent) || !std::isfinite(image.extent.size.width) ||
      !std::isfinite(image.extent.size.height))
    throw unsupported(path);
  if (!(readable_identity(path) == identity))
    throw SourceUnreadable("RAW source changed while opening");
  const auto w = std::llround(image.extent.size.width), h = std::llround(image.extent.size.height);
  if (w <= 0 || h <= 0 || !codec::raw_input_budget_ok(w, h))
    throw RawMemoryError("RAW dimensions exceed the supported pixel budget");
  auto value = std::make_unique<CachedRaw>();
  value->identity = identity;
  value->source_sha256 = source_sha256;
  value->filter = filter;
  value->width = w;
  value->height = h;
  value->processing.decoder_version = text(filter.decoderVersion);
  value->processing.os_build = raw_os_build();
  value->processing.baseline_exposure = baseline;
  value->processing.lens_correction_supported = filter.isLensCorrectionSupported;
  value->processing.lens_correction_applied =
      filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled;
  cached = std::move(value);
  return *cached;
}
CIContext* context() {
  static CIContext* context = [] {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) throw std::runtime_error("Apple RAW requires a Metal device");
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    CIContext* result = [CIContext contextWithMTLDevice:device
                                                options:@{
                                                  kCIContextWorkingColorSpace : (__bridge id)space,
                                                  kCIContextWorkingFormat : @(kCIFormatRGBAf),
                                                  kCIContextCacheIntermediates : @NO,
                                                  kCIContextName : @"HyperDR RAW"
                                                }];
    CGColorSpaceRelease(space);
    if (!result) throw std::runtime_error("cannot create Apple RAW rendering context");
    return result;
  }();
  return context;
}
void admission(unsigned source_width, unsigned source_height, unsigned width, unsigned height,
               unsigned rows) {
  const auto required =
      codec::ciraw_pipeline_bytes(source_width, source_height, width, height, rows);
  const auto budget = current_execution_config.memory_budget_bytes;
  constexpr std::uint64_t reserve = 512ULL * 1024 * 1024;
  const auto available = available_memory_bytes();
  if ((budget && required > budget) ||
      (available && (available <= reserve || required > available - reserve)))
    throw RawMemoryError("insufficient memory for Apple RAW decode (estimated " +
                         std::to_string(required) + " bytes)");
}
}  // namespace
std::string raw_os_build() {
  {
    std::lock_guard lock(override_mutex);
    if (!build_override.empty()) return build_override;
  }
  char value[128]{};
  std::size_t length = sizeof(value);
  if (sysctlbyname("kern.osversion", value, &length, nullptr, 0))
    throw std::runtime_error("cannot read the macOS build number");
  return value;
}
float raw_preview_scale(std::uint32_t edge, std::uint32_t source_edge) {
  if (!edge || !source_edge) return 1;
  for (float scale : {.125F, .25F, .5F, 1.F})
    if (source_edge * scale >= edge) return scale;
  return 1;
}
float raw_preview_scale(const std::filesystem::path& path, std::uint32_t edge) {
  if (!edge) return 1;
  @autoreleasepool {
    readable_identity(path);
    CGImageSourceRef source = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], nullptr);
    if (!source) return 1;
    NSDictionary* properties =
        CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    CFRelease(source);
    const auto w = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntValue];
    const auto h = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntValue];
    return raw_preview_scale(edge, std::max(w, h));
  }
}
RawHeader probe_apple_raw(const std::filesystem::path& path) {
  @autoreleasepool {
    auto lock = cancellable_cache_lock();
    auto& item = opened(path);
    return {item.width, item.height, item.processing};
  }
}
void release_apple_raw_cache(const std::filesystem::path& path) {
  @autoreleasepool {
    std::lock_guard lock(cache_mutex);
    std::error_code ec;
    const auto canonical = std::filesystem::weakly_canonical(path, ec);
    if (!ec && cached && cached->identity.path == canonical.string()) cached.reset();
  }
}
RawLensMetadata probe_raw_lens_metadata(const std::filesystem::path& path) {
  @autoreleasepool {
    auto lock = cancellable_cache_lock();
    auto& item = opened(path);
    NSDictionary* tiff = item.filter.properties[(__bridge NSString*)kCGImagePropertyTIFFDictionary];
    NSDictionary* exif = item.filter.properties[(__bridge NSString*)kCGImagePropertyExifDictionary];
    return {text(tiff[(__bridge NSString*)kCGImagePropertyTIFFMake]),
            text(tiff[(__bridge NSString*)kCGImagePropertyTIFFModel]),
            text(exif[(__bridge NSString*)kCGImagePropertyExifLensModel]),
            [exif[(__bridge NSString*)kCGImagePropertyExifFocalLength] doubleValue],
            [exif[(__bridge NSString*)kCGImagePropertyExifFNumber] doubleValue]};
  }
}
namespace codec {
DecodedImage decode_apple_raw(const std::filesystem::path& path, const RawDecodeOptions& options) {
  if (!options.profile.empty() || !options.look_profile.empty() || !options.lens_profile.empty() ||
      !options.bad_pixel_map.empty() || !options.dark_frame.empty() ||
      !options.linearization_lut.empty() || !options.lens_shading_map.empty() ||
      options.auto_bad_pixel_correction)
    throw std::invalid_argument("Apple RAW 引擎不支持该选项");
  if (!std::isfinite(options.digital_gain) || options.digital_gain <= 0)
    throw std::invalid_argument("invalid RAW digital gain");
  @autoreleasepool {
    auto lock = cancellable_cache_lock();
    auto& item = opened(path, options.source_sha256);
    CIRAWFilter* filter = item.filter;
    const float scale = raw_preview_scale(path, options.preview_max_edge);
    filter.scaleFactor = scale;
    if (filter.isLensCorrectionSupported) filter.lensCorrectionEnabled = options.lens_correction;
    CIImage* image = filter.outputImage;
    if (!image) throw unsupported(path);
    const auto width = static_cast<unsigned>(std::llround(image.extent.size.width));
    const auto height = static_cast<unsigned>(std::llround(image.extent.size.height));
    const auto block = std::max(64U, static_cast<unsigned>(std::lround(512 * scale)));
    admission(item.width, item.height, width, height, block);
    check_cancelled();  // Includes a cancellation requested while opening/downloading camera
                        // support.
    DecodedImage out;
    out.linear_p3 = FloatImage(width, height, 3);
    out.domain = InputDomain::kSceneReferred;
    out.source_color = {"Apple RAW", "Display P3", "Scene-linear", "apple-ciraw"};
    out.decode.source_width = out.decode.target_width = item.width;
    out.decode.source_height = out.decode.target_height = item.height;
    out.decode.sensor_width = item.width;
    out.decode.sensor_height = item.height;
    out.decode.decoded_width = width;
    out.decode.decoded_height = height;
    out.decode.raw = item.processing;
    out.decode.raw->digital_gain = options.digital_gain;
    out.decode.raw->scale = scale;
    out.decode.raw->block_rows = block;
    out.decode.raw->lens_correction_applied =
        filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled;
    const auto prefix = read_binary_prefix(path, 1U << 20U);
    if (!prefix.empty()) apply_exif(out, read_exif(prefix.data(), prefix.size()));
    out.metadata.orientation = 1;  // CIRAWFilter already rotated its output.
    std::vector<float> rgba(static_cast<std::size_t>(width) * block * 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
    struct Space {
      CGColorSpaceRef p;
      ~Space() { CGColorSpaceRelease(p); }
    } release{space};
    ++render_count;
    for (unsigned top = 0; top < height; top += block) {
      check_cancelled();
      const unsigned rows = std::min(block, height - top);
      const auto rect = CGRectMake(image.extent.origin.x,
                                   image.extent.origin.y + height - top - rows, width, rows);
      if (block_hook) block_hook(top, rows);
      CIContext* renderer = context();
      check_cancelled();  // Cold context setup must not commit a render after cancellation.
      [renderer render:image
               toBitmap:rgba.data()
               rowBytes:static_cast<std::size_t>(width) * 16
                 bounds:rect
                 format:kCIFormatRGBAf
             colorSpace:space];
      for (unsigned y = 0; y < rows; ++y)
        for (unsigned x = 0; x < width; ++x)
          for (unsigned c = 0; c < 3; ++c) {
            const float value =
                rgba[(static_cast<std::size_t>(y) * width + x) * 4 + c] * options.digital_gain;
            if (!std::isfinite(value))
              throw std::runtime_error("Apple RAW produced nonfinite pixels");
            out.linear_p3.at(x, top + y, c) = value;
          }
      if (options.progress_sink) {
        const auto name = path_utf8(path);
        options.progress_sink->on_progress({"decode", name, double(top + rows) / height, {}});
      }
    }
    check_cancelled();
    return out;
  }
}
}  // namespace codec
namespace testing {
std::uint64_t raw_filter_open_count() {
  std::lock_guard lock(cache_mutex);
  return open_count;
}
std::uint64_t raw_filter_render_count() {
  std::lock_guard lock(cache_mutex);
  return render_count;
}
void set_raw_block_hook(std::function<void(unsigned, unsigned)> value) {
  std::lock_guard lock(cache_mutex);
  block_hook = std::move(value);
}
void set_raw_open_hook(std::function<void()> value) {
  std::lock_guard lock(cache_mutex);
  open_hook = std::move(value);
}
std::string raw_neutral_settings() {
  @autoreleasepool {
    std::lock_guard lock(cache_mutex);
    if (!cached) throw std::runtime_error("no RAW filter");
    CIRAWFilter* f = cached->filter;
    json::Writer w;
    w.begin_object()
        .member("boost", f.boostAmount)
        .member("boostShadow", f.boostShadowAmount)
        .member("exposure", f.exposure)
        .member("baselineExposure", f.baselineExposure)
        .member("edr", f.extendedDynamicRangeAmount)
        .member("gamutMapping", bool(f.gamutMappingEnabled))
        .member("draft", bool(f.draftModeEnabled));
    if (f.isContrastSupported) w.member("contrast", f.contrastAmount);
    if (f.isSharpnessSupported) w.member("sharpness", f.sharpnessAmount);
    if (f.isDetailSupported) w.member("detail", f.detailAmount);
    if (f.isLocalToneMapSupported) w.member("localToneMap", f.localToneMapAmount);
    if (f.isLuminanceNoiseReductionSupported)
      w.member("luminanceNoise", f.luminanceNoiseReductionAmount);
    if (f.isColorNoiseReductionSupported) w.member("colorNoise", f.colorNoiseReductionAmount);
    if (f.isMoireReductionSupported) w.member("moire", f.moireReductionAmount);
    if (f.isDespeckleSupported) w.member("despeckle", f.despeckleAmount);
    return w.end_object().take();
  }
}
void set_raw_os_build_override(std::string value) {
  std::lock_guard lock(override_mutex);
  build_override = std::move(value);
}
}  // namespace testing
}  // namespace hyperdr

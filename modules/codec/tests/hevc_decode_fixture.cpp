#include "hevc_decode_fixture.hpp"

#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <string>

#include "hyperdr/foundation/file_io.hpp"
#include <exception>

#include "hevc/vt_common.hpp"
namespace hyperdr::codec::hevc::testing {
namespace {
DecodedPicture reference_picture(FixtureGeometry g) {
  // VT encodes monochrome full range; limited mono changes only its SPS below.
  if (g.chroma == 0) g.full_range = true;
  DecodedPicture input{g.width, g.height, g.depth, g.chroma, {}, {}};
  input.luma.resize(input.luma_row_bytes() * g.height);
  input.chroma.resize(input.chroma_row_bytes() * input.chroma_height());
  const auto put = [&](std::uint8_t* p, unsigned value) {
    if (g.depth == 8) *p = value;
    else {
      auto word = static_cast<std::uint16_t>(value << 6);
      std::memcpy(p, &word, 2);
    }
  };
  const unsigned scale = 1U << (g.depth - 8), low = (g.full_range ? 8 : 24) * scale,
                 range = (g.full_range ? 236 : 200) * scale, center = 1U << (g.depth - 1);
  for (unsigned row = 0; row < g.height; ++row)
    for (unsigned x = 0; x < g.width; ++x) {
      const unsigned code = low + (std::uint64_t(x) * (range - 16 * scale)) / (g.width - 1) +
                            (((x / 7) ^ (row / 5)) & 1) * 8 * scale + (row % 7) * scale;
      put(input.luma.data() + row * input.luma_row_bytes() + x * input.sample_bytes(), code);
    }
  for (std::size_t at = 0; at < input.chroma.size(); at += input.sample_bytes())
    put(input.chroma.data() + at, center);
  return input;
}

struct State {
  std::vector<std::uint8_t> configuration, sample;
  std::exception_ptr error;
};
void on_sample(void* context, void*, OSStatus status, VTEncodeInfoFlags, CMSampleBufferRef sample) {
  auto& s = *static_cast<State*>(context);
  try {
    check_status(status, "encode arbitrary HEVC fixture");
    if (!sample) throw std::runtime_error("missing HEVC fixture sample");
    const auto format = CMSampleBufferGetFormatDescription(sample);
    auto atoms = static_cast<CFDictionaryRef>(CMFormatDescriptionGetExtension(
        format, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms));
    if (!atoms) throw std::runtime_error("missing HEVC fixture atoms");
    auto config = static_cast<CFDataRef>(CFDictionaryGetValue(atoms, CFSTR("hvcC")));
    if (!config) throw std::runtime_error("missing fixture hvcC");
    s.configuration.assign(CFDataGetBytePtr(config),
                           CFDataGetBytePtr(config) + CFDataGetLength(config));
    auto block = CMSampleBufferGetDataBuffer(sample);
    s.sample.resize(CMBlockBufferGetDataLength(block));
    check_status(CMBlockBufferCopyDataBytes(block, 0, s.sample.size(), s.sample.data()),
                 "copy HEVC fixture");
  } catch (...) {
    s.error = std::current_exception();
  }
}
class Session {
 public:
  VTCompressionSessionRef value{};
  ~Session() {
    if (value) {
      VTCompressionSessionInvalidate(value);
      CFRelease(value);
    }
  }
};
}  // namespace
static DecodeFixture encode(const FixtureGeometry& geometry) {
  auto g = geometry;
  const bool limited_mono = g.chroma == 0 && !g.full_range;
  if (limited_mono) g.full_range = true;
  State state;
  Session session;
  check_status(
      VTCompressionSessionCreate(nullptr, g.width, g.height, kCMVideoCodecType_HEVC, nullptr,
                                 nullptr, nullptr, on_sample, &state, &session.value),
      "create fixture encoder");
  CFStringRef profile = nullptr;
  if (g.chroma == 0)
    profile = g.depth == 8 ? kVTProfileLevel_HEVC_Monochrome_AutoLevel
                           : kVTProfileLevel_HEVC_Monochrome10_AutoLevel;
  else if (g.chroma == 1)
    profile =
        g.depth == 8 ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_HEVC_Main10_AutoLevel;
  else if (g.chroma == 2)
    profile = kVTProfileLevel_HEVC_Main42210_AutoLevel;
  else
    profile = g.depth == 8 ? CFSTR("HEVC_Main444_AutoLevel") : CFSTR("HEVC_Main44410_AutoLevel");
  check_status(VTSessionSetProperty(session.value, kVTCompressionPropertyKey_ProfileLevel, profile),
               "set fixture profile");
  check_status(VTSessionSetProperty(session.value, kVTCompressionPropertyKey_AllowFrameReordering,
                                    kCFBooleanFalse),
               "disable fixture reordering");
  auto quality = cf_float(.95F);
  check_status(
      VTSessionSetProperty(session.value, kVTCompressionPropertyKey_Quality, quality.get()),
      "set fixture quality");
  check_status(VTSessionSetProperty(session.value, kVTCompressionPropertyKey_ColorPrimaries,
                                    kCVImageBufferColorPrimaries_ITU_R_709_2),
               "fixture primaries");
  check_status(VTSessionSetProperty(session.value, kVTCompressionPropertyKey_TransferFunction,
                                    kCVImageBufferTransferFunction_sRGB),
               "fixture transfer");
  check_status(VTSessionSetProperty(session.value, kVTCompressionPropertyKey_YCbCrMatrix,
                                    kCVImageBufferYCbCrMatrix_ITU_R_709_2),
               "fixture matrix");
  check_status(VTCompressionSessionPrepareToEncodeFrames(session.value), "prepare fixture encoder");
  OSType format;
  // Monochrome uses its native single-component source. Limited mono is
  // synthesized below because VT always writes full-range monochrome SPS.
  if (g.chroma == 0 && g.full_range)
    format = g.depth == 8 ? kCVPixelFormatType_OneComponent8 : kCVPixelFormatType_OneComponent10;
  else if (g.chroma <= 1)
    format = g.depth == 8 ? (g.full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                          : (g.full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                                          : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
  else if (g.chroma == 2)
    format = g.full_range ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                          : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
  else
    format = g.depth == 8 ? (g.full_range ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
                                          : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
                          : (g.full_range ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                                          : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange);
  CfRef<CVPixelBufferRef> pixel;
  check_status(CVPixelBufferCreate(nullptr, g.width, g.height, format, nullptr, pixel.out()),
               "allocate fixture pixel buffer");
  if (g.chroma_location) {
    auto location = *g.chroma_location ? kCVImageBufferChromaLocation_Center
                                       : kCVImageBufferChromaLocation_Left;
    CVBufferSetAttachment(pixel.get(), kCVImageBufferChromaLocationTopFieldKey, location,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel.get(), kCVImageBufferChromaLocationBottomFieldKey, location,
                          kCVAttachmentMode_ShouldPropagate);
  }
  auto input = reference_picture(g);
  check_status(CVPixelBufferLockBaseAddress(pixel.get(), 0), "lock fixture source");
  const bool planar = CVPixelBufferIsPlanar(pixel.get());
  auto* y = static_cast<std::uint8_t*>(planar ? CVPixelBufferGetBaseAddressOfPlane(pixel.get(), 0)
                                            : CVPixelBufferGetBaseAddress(pixel.get()));
  const auto stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixel.get(), 0)
                             : CVPixelBufferGetBytesPerRow(pixel.get());
  for (unsigned row = 0; row < g.height; ++row)
    std::memcpy(y + row * stride, input.luma.data() + row * input.luma_row_bytes(), input.luma_row_bytes());
  if (planar) {
    auto* uv = static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel.get(), 1));
    const auto stride_uv = CVPixelBufferGetBytesPerRowOfPlane(pixel.get(), 1);
    for (unsigned row = 0; row < input.chroma_height(); ++row)
      std::memcpy(uv + row * stride_uv, input.chroma.data() + row * input.chroma_row_bytes(), input.chroma_row_bytes());
  }
  CVPixelBufferUnlockBaseAddress(pixel.get(), 0);
  check_status(VTCompressionSessionEncodeFrame(session.value, pixel.get(), CMTimeMake(0, 1),
                                               kCMTimeInvalid, nullptr, nullptr, nullptr),
               "encode fixture frame");
  check_status(VTCompressionSessionCompleteFrames(session.value, kCMTimeInvalid),
               "complete fixture");
  if (state.error) std::rethrow_exception(state.error);

  auto config = parse_hevc_configuration(state.configuration);
  if (config.chroma_format != g.chroma || config.bit_depth != g.depth)
    throw std::runtime_error("VT encoded a different fixture chroma/depth");
  if (limited_mono) {
    // VT's monochrome encoder always writes full range. Relabel its known raw
    // codes by changing only video_full_range_flag, without changing slice
    // data. Find the flag through the independent hvcC/SPS parser rather than
    // freezing an OS-specific bit offset in the fixture.
    bool changed = false;
    for (std::size_t at = 23; at < state.configuration.size() && !changed; ++at)
      for (unsigned bit = 0; bit < 8 && !changed; ++bit) {
        auto candidate = state.configuration;
        candidate[at] ^= 1U << bit;
        try {
          auto parsed = parse_hevc_configuration(candidate);
          if (parsed.width == config.width && parsed.height == config.height &&
              parsed.chroma_format == 0 && parsed.bit_depth == g.depth && parsed.vui_color &&
              !parsed.vui_color->full_range && parsed.vui_color->primaries == 1 &&
              parsed.vui_color->transfer == 13 && parsed.vui_color->matrix == 1) {
            config = std::move(parsed);
            changed = true;
          }
        } catch (const HeifReadError&) {
        }
      }
    if (!changed) throw std::runtime_error("cannot construct video-range mono SPS");
  }
  return {std::move(config), std::move(state.sample), std::move(input)};
}
DecodeFixture fixture(const FixtureGeometry& g) {
  const auto name = std::to_string(g.width) + "x" + std::to_string(g.height) + "-" +
      std::to_string(g.depth) + "-" + std::to_string(g.chroma) + "-" +
      (g.full_range ? "full" : "video") + "-" +
      (g.chroma_location ? std::to_string(*g.chroma_location) : "default") + ".bin";
  const auto path = std::filesystem::path(HYPERDR_HEVC_DECODE_FIXTURES) / name;
  constexpr std::uint8_t magic[] = {'H', 'D', 'R', 'V', 'T', 1};
  if (const auto record = std::getenv("HYPERDR_RECORD_HEVC_FIXTURES"); record && std::string(record) == "1") {
    auto result = encode(g);
    // Store only hvcC and the compressed picture. The source is the fixed
    // analytic pattern above, so no uncompressed image needs to enter Git.
    std::vector<std::uint8_t> bytes(std::begin(magic), std::end(magic));
    const auto length = result.config.record.size();
    for (int shift : {24, 16, 8, 0}) bytes.push_back((length >> shift) & 255);
    bytes.insert(bytes.end(), result.config.record.begin(), result.config.record.end());
    bytes.insert(bytes.end(), result.sample.begin(), result.sample.end());
    std::filesystem::create_directories(path.parent_path());
    write_binary_file_atomic(path, bytes, true);
    return result;
  }
  if (std::filesystem::file_size(path) > 16 * 1024 * 1024)
    throw std::runtime_error("oversized HEVC decoder fixture: " + name);
  const auto bytes = read_binary_file(path);
  if (bytes.size() < 11 || !std::equal(std::begin(magic), std::end(magic), bytes.begin()))
    throw std::runtime_error("invalid HEVC decoder fixture: " + name);
  std::size_t length = 0;
  for (unsigned at = 6; at < 10; ++at) length = (length << 8) | bytes[at];
  if (!length || length > 1024 * 1024 || length >= bytes.size() - 10)
    throw std::runtime_error("invalid HEVC fixture configuration length: " + name);
  return {parse_hevc_configuration(std::span(bytes).subspan(10, length)),
          {bytes.begin() + 10 + length, bytes.end()}, reference_picture(g)};
}
}  // namespace hyperdr::codec::hevc::testing

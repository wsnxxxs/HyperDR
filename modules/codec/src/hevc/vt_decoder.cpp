#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <cstring>
#include <exception>
#include <map>
#include <mutex>

#include "hevc/vt_common.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/raster_budget.hpp"
namespace hyperdr::codec::hevc {
namespace {
CfRef<CMVideoFormatDescriptionRef> format_for(const EncodedSequence& sequence) {
  if (sequence.vps.empty() || sequence.sps.empty() || sequence.pps.empty())
    throw std::invalid_argument("HEVC sequence lacks parameter sets");
  const std::uint8_t* sets[] = {sequence.vps.data(), sequence.sps.data(), sequence.pps.data()};
  const std::size_t sizes[] = {sequence.vps.size(), sequence.sps.size(), sequence.pps.size()};
  CfRef<CMVideoFormatDescriptionRef> format;
  check_status(CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, sets,
                                                                   sizes, 4, nullptr, format.out()),
               "create HEVC format description");
  return format;
}
CfRef<CMVideoFormatDescriptionRef> format_for(const HvcConfig& config) {
  std::vector<const std::uint8_t*> sets;
  std::vector<std::size_t> sizes;
  for (const auto& set : config.parameter_sets) {
    if (set.size() < 2) throw HeifReadError("truncated HEVC parameter set");
    auto type = (set[0] >> 1) & 63;
    if (type < 32 || type > 34) continue;
    sets.push_back(set.data());
    sizes.push_back(set.size());
  }
  CfRef<CMVideoFormatDescriptionRef> format;
  const auto status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
      kCFAllocatorDefault, sets.size(), sets.data(), sizes.data(), config.length_size, nullptr,
      format.out());
  if (status)
    throw HeifReadError("cannot create HEVC format (OSStatus " + std::to_string(status) + ")");
  const auto size = CMVideoFormatDescriptionGetDimensions(format.get());
  if (size.width <= 0 || size.height <= 0 ||
      static_cast<std::uint32_t>(size.width) != config.width ||
      static_cast<std::uint32_t>(size.height) != config.height)
    throw HeifReadError("CoreMedia HEVC dimensions differ from SPS");
  return format;
}
OSType output_format(const HvcConfig& c) {
  if (c.bit_depth != 8 && c.bit_depth != 10)
    throw HeifReadError("HEVC bit depth is not supported",
                        c.bit_depth == 12 ? "hevc_12bit" : "hevc_bit_depth");
  const bool full = c.vui_color && c.vui_color->full_range;
  switch (c.chroma_format) {
    case 0:
      return c.bit_depth == 8 ? kCVPixelFormatType_OneComponent8
                              : kCVPixelFormatType_OneComponent10;
    case 1:
      return c.bit_depth == 8 ? (full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                      : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                              : (full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                                      : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
    case 2:
      if (c.bit_depth == 10)
        return full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                    : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
      break;
    case 3:
      return c.bit_depth == 8 ? (full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
                                      : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
                              : (full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                                      : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange);
  }
  throw HeifReadError("HEVC chroma format is not supported", "hevc_chroma");
}
struct DecodeState {
  std::mutex mutex;
  std::exception_ptr error;
  HvcConfig config;
  OSType pixel{};
  const CancelToken* cancel{};
  std::vector<bool> returned;
  std::map<std::size_t, DecodedPicture> ready;
};
DecodedPicture copy_picture(const DecodeState& state, CVImageBufferRef image) {
  const auto& c = state.config;
  if (!image || CVPixelBufferGetPixelFormatType(image) != state.pixel ||
      CVPixelBufferGetWidth(image) != c.width || CVPixelBufferGetHeight(image) != c.height ||
      CVPixelBufferGetPlaneCount(image) != (c.chroma_format ? 2U : 0U))
    throw HeifReadError("VideoToolbox returned an unexpected HEVC picture format");
  DecodedPicture p{c.width, c.height, c.bit_depth, c.chroma_format, {}, {}};
  p.luma.resize(p.luma_row_bytes() * p.height);
  p.chroma.resize(p.chroma_row_bytes() * p.chroma_height());
  const auto copy = [&](std::size_t plane, std::vector<std::uint8_t>& out, std::size_t row_bytes,
                        std::size_t rows) {
    const auto* source = static_cast<const std::uint8_t*>(
        c.chroma_format ? CVPixelBufferGetBaseAddressOfPlane(image, plane)
                        : CVPixelBufferGetBaseAddress(image));
    const auto stride = c.chroma_format ? CVPixelBufferGetBytesPerRowOfPlane(image, plane)
                                        : CVPixelBufferGetBytesPerRow(image);
    if (!source || stride < row_bytes ||
        (c.chroma_format &&
         (CVPixelBufferGetWidthOfPlane(image, plane) != (plane ? p.chroma_width() : p.width) ||
          CVPixelBufferGetHeightOfPlane(image, plane) != rows)))
      throw HeifReadError("VideoToolbox returned an invalid HEVC plane layout");
    for (std::size_t y = 0; y < rows; ++y) {
      if ((y & 31) == 0 && state.cancel) state.cancel->check();
      std::memcpy(out.data() + y * row_bytes, source + y * stride, row_bytes);
    }
  };
  check_status(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly),
               "lock HEVC picture");
  try {
    copy(0, p.luma, p.luma_row_bytes(), p.height);
    if (c.chroma_format) copy(1, p.chroma, p.chroma_row_bytes(), p.chroma_height());
  } catch (...) {
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    throw;
  }
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  return p;
}
void on_picture(void* refcon, void* frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
                CVImageBufferRef image, CMTime, CMTime) {
  auto& s = *static_cast<DecodeState*>(refcon);
  std::lock_guard lock(s.mutex);
  try {
    const auto encoded_index = reinterpret_cast<std::uintptr_t>(frame_refcon);
    if (!encoded_index || encoded_index > s.returned.size() || s.returned[encoded_index - 1])
      throw HeifReadError("VideoToolbox returned an unexpected HEVC frame count");
    const auto index = encoded_index - 1;
    s.returned[index] = true;
    if (status)
      throw HeifReadError("VideoToolbox HEVC callback failed (OSStatus " + std::to_string(status) +
                          ")");
    if (flags & kVTDecodeInfo_FrameDropped)
      throw HeifReadError("VideoToolbox dropped an HEVC picture");
    // VT can conceal entropy-coded damage that preserves legal slice syntax.
    // Framing/header validation and callback checks cannot prove every pixel's
    // integrity; do not advertise this path as a complete corruption detector.
    if (!s.cancel || !s.cancel->requested()) s.ready.emplace(index, copy_picture(s, image));
  } catch (...) {
    if (!s.error) s.error = std::current_exception();
  }
}
class DecompressionGuard {
 public:
  ~DecompressionGuard() {
    if (session_) {
      VTDecompressionSessionWaitForAsynchronousFrames(session_);
      VTDecompressionSessionInvalidate(session_);
      CFRelease(session_);
    }
  }
  VTDecompressionSessionRef* out() { return &session_; }
  VTDecompressionSessionRef get() const { return session_; }

 private:
  VTDecompressionSessionRef session_{};
};
void submit(VTDecompressionSessionRef session, CMVideoFormatDescriptionRef format,
            std::span<const std::uint8_t> sample, std::size_t index) {
  CfRef<CMBlockBufferRef> block;
  check_status(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, sample.size(),
                                                  kCFAllocatorDefault, nullptr, 0, sample.size(),
                                                  kCMBlockBufferAssureMemoryNowFlag, block.out()),
               "allocate HEVC sample buffer");
  check_status(CMBlockBufferReplaceDataBytes(sample.data(), block.get(), 0, sample.size()),
               "copy HEVC sample bytes");
  CfRef<CMSampleBufferRef> buffer;
  const auto size = sample.size();
  check_status(CMSampleBufferCreateReady(kCFAllocatorDefault, block.get(), format, 1, 0, nullptr, 1,
                                         &size, buffer.out()),
               "create HEVC sample");
  VTDecodeInfoFlags flags = 0;
  const auto status = VTDecompressionSessionDecodeFrame(
      session, buffer.get(), kVTDecodeFrame_EnableAsynchronousDecompression,
      reinterpret_cast<void*>(static_cast<std::uintptr_t>(index + 1)), &flags);
  if (status || flags & kVTDecodeInfo_FrameDropped)
    throw HeifReadError("VideoToolbox HEVC submission failed (OSStatus " + std::to_string(status) +
                        ")");
}
}  // namespace
void decode_item(const HvcConfig& config, std::size_t count, const EncodedTileReader& reader,
                 const DecodedTileSink& sink, const DecodeParams& params) {
  CancelScope cancellation(params.cancel ? params.cancel : current_cancel_token);
  check_cancelled();
  if (!reader || !sink || !count || count > heif_limits::grid_tiles)
    throw std::invalid_argument("invalid HEVC item callbacks or tile count");
  if (!raster_geometry_ok(config.width, config.height))
    throw HeifReadError("HEVC tile exceeds raster budget");
  const auto pixels = output_format(config);
  const auto format = format_for(config);
  DecodeState state;
  state.config = config;
  state.pixel = pixels;
  state.cancel = current_cancel_token;
  state.returned.assign(count, false);
  const auto attributes = cf_dictionary();
  const auto pixel = cf_int(static_cast<int>(pixels));
  if (!attributes || !pixel) throw HeifReadError("cannot allocate HEVC decode attributes");
  CFDictionarySetValue(attributes.get(), kCVPixelBufferPixelFormatTypeKey, pixel.get());
  const VTDecompressionOutputCallbackRecord callback{&on_picture, &state};
  DecompressionGuard session;
  const auto status = VTDecompressionSessionCreate(kCFAllocatorDefault, format.get(), nullptr,
                                                   attributes.get(), &callback, session.out());
  if (status) {
    const bool unsupported = status == kVTCouldNotFindVideoDecoderErr ||
                             status == kVTVideoDecoderUnsupportedDataFormatErr;
    throw HeifReadError("cannot create HEVC decoder (OSStatus " + std::to_string(status) + ")",
                        unsupported ? (config.chroma_format == 3   ? "hevc_444"
                                       : config.chroma_format == 2 ? "hevc_422"
                                                                   : "hevc_decoder")
                                    : "");
  }
  const std::uint64_t native_bytes = std::uint64_t(config.width) * config.height *
                                     (config.bit_depth > 8 ? 2 : 1) *
                                     (config.chroma_format == 0   ? 1
                                      : config.chroma_format == 1 ? 2
                                      : config.chroma_format == 2 ? 2
                                                                  : 3);
  const auto capacity = std::max<std::size_t>(
      1,
      std::min<std::size_t>({4, params.max_in_flight ? params.max_in_flight : 4,
                             static_cast<std::size_t>((8 * 1024 * 1024) /
                                                      std::max<std::uint64_t>(1, native_bytes))}));
  if (params.progress) params.progress(0, count);
  std::size_t submitted = 0;
  for (std::size_t index = 0; index < count; ++index) {
    while (submitted < count && submitted - index < capacity) {
      check_cancelled();
      auto bytes = reader(submitted);
      validate_hevc_sample(bytes, config);
      check_cancelled();
      submit(session.get(), format.get(), bytes, submitted++);
    }
    DecodedPicture picture;
    {
      std::unique_lock lock(state.mutex);
      if (!state.ready.contains(index) && !state.error) {
        // Draining also detects a sample for which VT silently produced no
        // callback, rather than waiting forever for a nonexistent frame.
        lock.unlock();
        check_status(VTDecompressionSessionWaitForAsynchronousFrames(session.get()),
                     "drain HEVC decode");
        lock.lock();
        if (!state.ready.contains(index) && !state.error &&
            (!state.cancel || !state.cancel->requested()))
          throw HeifReadError("VideoToolbox produced no HEVC frame for a sample");
      }
      check_cancelled();
      if (state.error) std::rethrow_exception(state.error);
      picture = std::move(state.ready.at(index));
      state.ready.erase(index);
    }
    sink(index, std::move(picture));
    check_cancelled();
    if (params.progress && index + 1 < count) params.progress(index + 1, count);
  }
  check_status(VTDecompressionSessionWaitForAsynchronousFrames(session.get()),
               "finish HEVC decode");
  {
    std::lock_guard lock(state.mutex);
    if (state.error) std::rethrow_exception(state.error);
    for (bool returned : state.returned)
      if (!returned) throw HeifReadError("VideoToolbox did not return every HEVC frame");
  }
  if (params.progress) params.progress(count, count);
  check_cancelled();
}
std::vector<YuvTile> decode(const EncodedSequence& sequence, int bit_depth) {
  (void)make_tile(bit_depth);
  const auto config = parse_hevc_configuration(
      make_hevc_configuration(sequence.vps, sequence.sps, sequence.pps).record);
  if (config.width != kTileSize || config.height != kTileSize || config.chroma_format != 1 ||
      config.bit_depth != static_cast<unsigned>(bit_depth))
    throw std::invalid_argument("HEVC sequence differs from the encoder tile format");
  std::vector<YuvTile> tiles(sequence.samples.size());
  if (tiles.empty()) return tiles;
  decode_item(
      config, tiles.size(),
      [&](std::size_t i) -> std::span<const std::uint8_t> { return sequence.samples[i]; },
      [&](std::size_t i, DecodedPicture&& p) {
        tiles[i] = {bit_depth, std::move(p.luma), std::move(p.chroma)};
      });
  return tiles;
}

BitstreamColor bitstream_color(const EncodedSequence& sequence) {
  const auto format = format_for(sequence);
  BitstreamColor result;
  result.color.primaries = h273_primaries(
      CMFormatDescriptionGetExtension(format.get(), kCMFormatDescriptionExtension_ColorPrimaries));
  result.color.transfer = h273_transfer(CMFormatDescriptionGetExtension(
      format.get(), kCMFormatDescriptionExtension_TransferFunction));
  result.color.matrix = h273_matrix(
      CMFormatDescriptionGetExtension(format.get(), kCMFormatDescriptionExtension_YCbCrMatrix));
  const auto full =
      CMFormatDescriptionGetExtension(format.get(), kCMFormatDescriptionExtension_FullRangeVideo);
  result.full_range = full && CFGetTypeID(full) == CFBooleanGetTypeID() &&
                      CFBooleanGetValue(static_cast<CFBooleanRef>(full));
  return result;
}

}  // namespace hyperdr::codec::hevc

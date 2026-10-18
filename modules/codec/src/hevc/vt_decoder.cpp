#include "hevc/vt_common.hpp"

#include <VideoToolbox/VideoToolbox.h>

#include <exception>
#include <mutex>

namespace hyperdr::codec::hevc {
namespace {

CfRef<CMVideoFormatDescriptionRef> format_for(const EncodedSequence& sequence) {
  if (sequence.vps.empty() || sequence.sps.empty() || sequence.pps.empty()) {
    throw std::invalid_argument("HEVC sequence lacks parameter sets");
  }
  const std::uint8_t* sets[] = {sequence.vps.data(), sequence.sps.data(), sequence.pps.data()};
  const std::size_t sizes[] = {sequence.vps.size(), sequence.sps.size(), sequence.pps.size()};
  CfRef<CMVideoFormatDescriptionRef> format;
  check_status(CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                   kCFAllocatorDefault, 3, sets, sizes, 4, nullptr, format.out()),
               "create HEVC format description");
  return format;
}

struct DecodeState {
  std::mutex mutex;
  std::string error;
  int bit_depth{8};
  std::vector<YuvTile> tiles;
  std::vector<bool> present;
};

void record_picture(DecodeState& state, std::size_t index, OSStatus status,
                    VTDecodeInfoFlags flags, CVImageBufferRef image) {
  if (status != noErr) throw VtError("VideoToolbox HEVC decode", status);
  if (flags & kVTDecodeInfo_FrameDropped) throw VtError("VideoToolbox dropped an HEVC picture");
  if (!image) throw VtError("VideoToolbox returned no picture");
  if (index >= state.tiles.size() || state.present[index]) {
    throw VtError("VideoToolbox returned an unexpected picture");
  }
  if (CVPixelBufferGetPixelFormatType(image) != pixel_format(state.bit_depth) ||
      CVPixelBufferGetWidth(image) != kTileSize || CVPixelBufferGetHeight(image) != kTileSize) {
    throw VtError("decoded HEVC picture has an unexpected format");
  }
  auto tile = make_tile(state.bit_depth);
  check_status(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly),
               "lock decoded picture");
  try {
    copy_plane_from_buffer(image, 0, tile.luma.data(), tile.luma_row_bytes(), kTileSize);
    copy_plane_from_buffer(image, 1, tile.chroma.data(), tile.chroma_row_bytes(), kTileSize / 2);
  } catch (...) {
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    throw;
  }
  CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
  state.tiles[index] = std::move(tile);
  state.present[index] = true;
}

void on_picture(void* refcon, void* frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
                CVImageBufferRef image, CMTime, CMTime) {
  auto& state = *static_cast<DecodeState*>(refcon);
  std::lock_guard lock(state.mutex);
  try {
    record_picture(state, reinterpret_cast<std::uintptr_t>(frame_refcon), status, flags, image);
  } catch (const std::exception& error) {
    if (state.error.empty()) state.error = error.what();
  } catch (...) {
    if (state.error.empty()) state.error = "HEVC decode callback failed";
  }
}

class DecompressionGuard {
 public:
  DecompressionGuard() = default;
  DecompressionGuard(const DecompressionGuard&) = delete;
  DecompressionGuard& operator=(const DecompressionGuard&) = delete;
  ~DecompressionGuard() {
    if (!session_) return;
    VTDecompressionSessionWaitForAsynchronousFrames(session_);
    VTDecompressionSessionInvalidate(session_);
    CFRelease(session_);
  }
  VTDecompressionSessionRef* out() noexcept { return &session_; }
  [[nodiscard]] VTDecompressionSessionRef get() const noexcept { return session_; }

 private:
  VTDecompressionSessionRef session_{};
};

}  // namespace

std::vector<YuvTile> decode(const EncodedSequence& sequence, int bit_depth) {
  (void)make_tile(bit_depth);  // validates the depth
  const auto format = format_for(sequence);

  DecodeState state;
  state.bit_depth = bit_depth;
  state.tiles.resize(sequence.samples.size());
  state.present.assign(sequence.samples.size(), false);

  const auto attributes = cf_dictionary();
  const auto pixels = cf_int(static_cast<int>(pixel_format(bit_depth)));
  if (!attributes || !pixels) throw VtError("cannot allocate HEVC decode attributes");
  CFDictionarySetValue(attributes.get(), kCVPixelBufferPixelFormatTypeKey, pixels.get());

  const VTDecompressionOutputCallbackRecord callback{&on_picture, &state};
  DecompressionGuard session;
  check_status(VTDecompressionSessionCreate(kCFAllocatorDefault, format.get(), nullptr,
                                            attributes.get(), &callback, session.out()),
               "create HEVC decompression session");

  for (std::size_t index = 0; index < sequence.samples.size(); ++index) {
    const auto& sample = sequence.samples[index];
    if (sample.empty()) throw std::invalid_argument("empty HEVC sample");
    CfRef<CMBlockBufferRef> block;
    check_status(CMBlockBufferCreateWithMemoryBlock(
                     kCFAllocatorDefault, const_cast<std::uint8_t*>(sample.data()), sample.size(),
                     kCFAllocatorNull, nullptr, 0, sample.size(), 0, block.out()),
                 "wrap HEVC sample");
    CfRef<CMSampleBufferRef> buffer;
    const std::size_t sample_size = sample.size();
    check_status(CMSampleBufferCreateReady(kCFAllocatorDefault, block.get(), format.get(), 1, 0,
                                           nullptr, 1, &sample_size, buffer.out()),
                 "create HEVC sample buffer");
    VTDecodeInfoFlags flags = 0;
    // Synchronous: the sample memory is borrowed, so it must be consumed
    // before the next iteration.
    check_status(VTDecompressionSessionDecodeFrame(
                     session.get(), buffer.get(), 0,
                     reinterpret_cast<void*>(static_cast<std::uintptr_t>(index)), &flags),
                 "decode HEVC picture");
  }
  check_status(VTDecompressionSessionWaitForAsynchronousFrames(session.get()),
               "finish HEVC decode");

  std::lock_guard lock(state.mutex);
  if (!state.error.empty()) throw VtError(state.error);
  for (const bool present : state.present) {
    if (!present) throw VtError("VideoToolbox did not return every picture");
  }
  return std::move(state.tiles);
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
  const auto full = CMFormatDescriptionGetExtension(format.get(),
                                                    kCMFormatDescriptionExtension_FullRangeVideo);
  result.full_range = full && CFGetTypeID(full) == CFBooleanGetTypeID() &&
                      CFBooleanGetValue(static_cast<CFBooleanRef>(full));
  return result;
}

}  // namespace hyperdr::codec::hevc

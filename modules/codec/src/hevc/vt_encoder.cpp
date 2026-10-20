#include "hevc/vt_common.hpp"
#include "hevc/testing.hpp"

#include "hyperdr/foundation/cancel.hpp"

#include <VideoToolbox/VideoToolbox.h>

#include <chrono>
#include <condition_variable>
#include <cstring>
#include <exception>
#include <mutex>

namespace hyperdr::codec::hevc {
namespace {

// Pictures handed to VideoToolbox but not yet returned. A few keep the
// hardware busy; more would only hold pixel buffers.
constexpr std::size_t kMaxInFlight = 4;

void validate_tile(const YuvTile& tile, int bit_depth) {
  const std::size_t luma_bytes = static_cast<std::size_t>(kTileSize) * kTileSize *
                                 (bit_depth > 8 ? 2U : 1U);
  if (tile.bit_depth != bit_depth || tile.luma.size() != luma_bytes ||
      tile.chroma.size() != luma_bytes / 2) {
    throw std::invalid_argument("HEVC tile does not match the profile");
  }
}

struct ParameterSets {
  std::vector<std::uint8_t> vps, sps, pps;
  bool operator==(const ParameterSets&) const = default;
};

// Shared with the output callback, which VideoToolbox runs on its own thread.
// Lives until the session has been completed and invalidated (SessionGuard).
struct OutputState {
  std::mutex mutex;
  std::condition_variable changed;
  std::size_t count{};
  std::size_t returned{};
  std::string error;  // the first failure, reported once encoding stops
  bool have_sets{false};
  ParameterSets sets;
  std::vector<std::vector<std::uint8_t>> samples;
  std::vector<bool> present;
  std::vector<std::vector<std::uint8_t>> with_unspecified;
};

void fail(OutputState& state, std::string message) {
  if (state.error.empty()) state.error = std::move(message);
}

ParameterSets parameter_sets(CMFormatDescriptionRef format, int& length_size) {
  std::size_t count = 0;
  check_status(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, nullptr, nullptr,
                                                                 &count, &length_size),
               "read HEVC parameter set count");
  ParameterSets sets;
  for (std::size_t i = 0; i < count; ++i) {
    const std::uint8_t* data = nullptr;
    std::size_t size = 0;
    check_status(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &data, &size,
                                                                   nullptr, nullptr),
                 "read HEVC parameter set");
    if (!data || size < 2) throw VtError("HEVC parameter set is truncated");
    // Picked by NAL type, not position: the array may also carry SEI.
    std::vector<std::uint8_t>* slot = nullptr;
    switch (nal_type(data)) {
      case kNalVps: slot = &sets.vps; break;
      case kNalSps: slot = &sets.sps; break;
      case kNalPps: slot = &sets.pps; break;
      default: continue;
    }
    if (!slot->empty()) throw VtError("HEVC format description repeats a parameter set");
    slot->assign(data, data + size);
  }
  if (sets.vps.empty() || sets.sps.empty() || sets.pps.empty()) {
    throw VtError("HEVC format description lacks VPS, SPS or PPS");
  }
  if (length_size != 1 && length_size != 2 && length_size != 4) {
    throw VtError("HEVC sample uses an unsupported NAL length size");
  }
  return sets;
}

// The picture's NAL units with 4-byte lengths, without access unit delimiters,
// SEI or in-band parameter sets (hvcC carries those). Every slice must be IDR.
std::vector<std::uint8_t> repack_sample(const std::vector<std::uint8_t>& data, int length_size,
                                        const ParameterSets& sets, std::vector<std::uint8_t>* with_unspecified = nullptr) {
  std::vector<std::uint8_t> out;
  out.reserve(data.size());
  bool has_slice = false;
  std::size_t at = 0;
  const auto length_bytes = static_cast<std::size_t>(length_size);
  while (at < data.size()) {
    if (data.size() - at < length_bytes) throw VtError("HEVC sample ends inside a NAL length");
    std::size_t length = 0;
    for (std::size_t i = 0; i < length_bytes; ++i) length = (length << 8U) | data[at + i];
    at += length_bytes;
    if (length < 2 || length > data.size() - at) throw VtError("HEVC NAL length overruns the sample");
    const std::uint8_t* nal = data.data() + at;
    at += length;
    if ((nal[0] & 0x81U) || (nal[1] >> 3U) || !(nal[1] & 7U))
      throw VtError("HEVC sample has an invalid single-layer NAL header");
    const int type = nal_type(nal);
    if (type == kNalAud || type == kNalPrefixSei || type == kNalSuffixSei) continue;
    if (type == kNalVps || type == kNalSps || type == kNalPps) {
      const auto& expected = type == kNalVps ? sets.vps : type == kNalSps ? sets.sps : sets.pps;
      if (expected.size() != length || std::memcmp(expected.data(), nal, length) != 0) {
        throw VtError("HEVC sample carries a different in-band parameter set");
      }
      continue;
    }
    const bool unspecified = type >= 48; // H.265: decoder shall ignore UNSPEC48..63.
    if (type < 32) {
      if (type != kNalIdrWRadl && type != kNalIdrNLp) throw VtError("HEVC picture is not IDR");
      has_slice = true;
    } else if (!unspecified && type != 38) {
      // AUD/SEI were removed above, matching the existing HEIF policy. Filler
      // is allowed by the writer. Reserved types (41..47), EOS/EOB and any
      // other unexpected non-VCL type must never be silently discarded.
      throw VtError("unexpected HEVC NAL type " + std::to_string(type));
    }
    const auto append = [&](std::vector<std::uint8_t>& target) {
      if (length > 0xFFFFFFFFU) throw VtError("HEVC NAL unit is too large");
      for (int shift = 24; shift >= 0; shift -= 8)
        target.push_back(static_cast<std::uint8_t>((length >> static_cast<unsigned>(shift)) & 0xFFU));
      target.insert(target.end(), nal, nal + length);
    };
    if (with_unspecified) append(*with_unspecified);
    if (!unspecified) append(out);
  }
  if (!has_slice) throw VtError("HEVC sample has no slice");
  return out;
}

void record_frame(OutputState& state, std::size_t index, OSStatus status,
                  VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
  if (status != noErr) throw VtError("VideoToolbox HEVC encode", status);
  if (flags & kVTEncodeInfo_FrameDropped) throw VtError("VideoToolbox dropped an HEVC picture");
  if (!sample) throw VtError("VideoToolbox returned no HEVC sample");
  if (index >= state.count || state.present[index]) {
    throw VtError("VideoToolbox returned an unexpected HEVC picture");
  }
  CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
  if (!format) throw VtError("HEVC sample has no format description");
  int length_size = 0;
  auto sets = parameter_sets(format, length_size);
  if (!state.have_sets) {
    state.sets = std::move(sets);
    state.have_sets = true;
  } else if (!(sets == state.sets)) {
    throw VtError("HEVC parameter sets changed between tiles");
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  if (!block) throw VtError("HEVC sample has no data");
  std::vector<std::uint8_t> data(CMBlockBufferGetDataLength(block));
  check_status(CMBlockBufferCopyDataBytes(block, 0, data.size(), data.data()),
               "copy HEVC sample");
  state.samples[index] = repack_sample(data, length_size, state.sets,
      state.with_unspecified.empty() ? nullptr : &state.with_unspecified[index]);
  state.present[index] = true;
}

// VideoToolbox's thread: nothing may escape as a C++ exception.
void on_output(void* refcon, void* frame_refcon, OSStatus status, VTEncodeInfoFlags flags,
               CMSampleBufferRef sample) {
  auto& state = *static_cast<OutputState*>(refcon);
  const auto index = reinterpret_cast<std::uintptr_t>(frame_refcon);
  {
    std::lock_guard lock(state.mutex);
    try {
      record_frame(state, index, status, flags, sample);
    } catch (const std::exception& error) {
      fail(state, error.what());
    } catch (...) {
      fail(state, "HEVC output callback failed");
    }
    ++state.returned;
  }
  state.changed.notify_all();
}

// Completes and invalidates the session before OutputState can go away, on
// every path: success, cancellation and failure.
class SessionGuard {
 public:
  SessionGuard() = default;
  SessionGuard(const SessionGuard&) = delete;
  SessionGuard& operator=(const SessionGuard&) = delete;
  ~SessionGuard() {
    if (!session_) return;
    VTCompressionSessionCompleteFrames(session_, kCMTimeInvalid);
    VTCompressionSessionInvalidate(session_);
    CFRelease(session_);
  }
  VTCompressionSessionRef* out() noexcept { return &session_; }
  [[nodiscard]] VTCompressionSessionRef get() const noexcept { return session_; }

 private:
  VTCompressionSessionRef session_{};
};

void set_property(VTCompressionSessionRef session, CFStringRef key, CFTypeRef value,
                  const char* name) {
  if (!value) throw VtError(std::string("cannot create value for ") + name);
  check_status(VTSessionSetProperty(session, key, value), name);
}

void attach_color(CVPixelBufferRef buffer, const ColorDescription& color) {
  if (const auto value = cv_primaries(color.primaries)) {
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, value,
                          kCVAttachmentMode_ShouldPropagate);
  }
  if (const auto value = cv_transfer(color.transfer)) {
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, value,
                          kCVAttachmentMode_ShouldPropagate);
  }
  if (const auto value = cv_matrix(color.matrix)) {
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, value,
                          kCVAttachmentMode_ShouldPropagate);
  }
}

void configure(VTCompressionSessionRef session, const EncodeParams& params) {
  set_property(session, kVTCompressionPropertyKey_ProfileLevel,
               params.main10 ? kVTProfileLevel_HEVC_Main10_AutoLevel
                             : kVTProfileLevel_HEVC_Main_AutoLevel,
               "set HEVC profile");
  set_property(session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse, "disable real time");
  set_property(session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse,
               "disable frame reordering");
  const auto interval = cf_int(1);
  set_property(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, interval.get(),
               "set keyframe interval");
  const auto quality = cf_float(vt_quality(params.quality, params.main10, params.quality_role, params.color.transfer));
  set_property(session, kVTCompressionPropertyKey_Quality, quality.get(), "set HEVC quality");
  if (const auto value = cv_primaries(params.color.primaries)) {
    set_property(session, kVTCompressionPropertyKey_ColorPrimaries, value, "set colour primaries");
  }
  if (const auto value = cv_transfer(params.color.transfer)) {
    set_property(session, kVTCompressionPropertyKey_TransferFunction, value,
                 "set transfer function");
  }
  if (const auto value = cv_matrix(params.color.matrix)) {
    set_property(session, kVTCompressionPropertyKey_YCbCrMatrix, value, "set YCbCr matrix");
  }
}

EncodedSequence run(std::size_t count, const TileProducer& produce, const EncodeParams& params, EncodedSequence* audit = nullptr) {
  if (count == 0) throw std::invalid_argument("HEVC sequence has no tiles");
  const int bit_depth = params.main10 ? 10 : 8;
  // Rejects unsupported colour code points before any session exists.
  (void)cv_primaries(params.color.primaries);
  (void)cv_transfer(params.color.transfer);
  (void)cv_matrix(params.color.matrix);

  OutputState state;
  state.count = count;
  state.samples.resize(count);
  if (audit) state.with_unspecified.resize(count);
  state.present.assign(count, false);

  const auto attributes = cf_dictionary();
  const auto format = cf_int(static_cast<int>(pixel_format(bit_depth)));
  const auto size = cf_int(static_cast<int>(kTileSize));
  const auto surface = cf_dictionary();
  if (!attributes || !format || !size || !surface) throw VtError("cannot allocate HEVC attributes");
  CFDictionarySetValue(attributes.get(), kCVPixelBufferPixelFormatTypeKey, format.get());
  CFDictionarySetValue(attributes.get(), kCVPixelBufferWidthKey, size.get());
  CFDictionarySetValue(attributes.get(), kCVPixelBufferHeightKey, size.get());
  CFDictionarySetValue(attributes.get(), kCVPixelBufferIOSurfacePropertiesKey, surface.get());

  SessionGuard session;
  check_status(VTCompressionSessionCreate(kCFAllocatorDefault, static_cast<int32_t>(kTileSize),
                                          static_cast<int32_t>(kTileSize), kCMVideoCodecType_HEVC,
                                          nullptr, attributes.get(), nullptr, &on_output, &state,
                                          session.out()),
               "create HEVC compression session");
  configure(session.get(), params);
  check_status(VTCompressionSessionPrepareToEncodeFrames(session.get()), "prepare HEVC session");
  CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(session.get());
  if (!pool) throw VtError("HEVC session has no pixel buffer pool");

  const auto frame_options = cf_dictionary();
  if (!frame_options) throw VtError("cannot allocate HEVC frame options");
  CFDictionarySetValue(frame_options.get(), kVTEncodeFrameOptionKey_ForceKeyFrame, kCFBooleanTrue);

  const auto throw_if_failed = [&state] {
    std::lock_guard lock(state.mutex);
    if (!state.error.empty()) throw VtError(state.error);
  };

  auto tile = make_tile(bit_depth);
  for (std::size_t index = 0; index < count; ++index) {
    check_cancelled();
    // Back-pressure. VideoToolbox may hold pictures until it sees more input,
    // so a wait that makes no progress flushes what has been submitted.
    {
      std::unique_lock lock(state.mutex);
      while (state.error.empty() && index - state.returned >= kMaxInFlight) {
        if (!state.changed.wait_for(lock, std::chrono::milliseconds(50), [&] {
              return !state.error.empty() || index - state.returned < kMaxInFlight;
            })) {
          lock.unlock();
          check_status(VTCompressionSessionCompleteFrames(
                           session.get(), CMTimeMake(static_cast<int64_t>(index) - 1, 1)),
                       "flush HEVC pictures");
          lock.lock();
        }
      }
    }
    throw_if_failed();

    produce(index, tile);
    validate_tile(tile, bit_depth);
    CfRef<CVPixelBufferRef> buffer;
    check_status(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, buffer.out()),
                 "create HEVC pixel buffer");
    check_status(CVPixelBufferLockBaseAddress(buffer.get(), 0), "lock HEVC pixel buffer");
    try {
      copy_plane_to_buffer(buffer.get(), 0, tile.luma.data(), tile.luma_row_bytes(), kTileSize);
      copy_plane_to_buffer(buffer.get(), 1, tile.chroma.data(), tile.chroma_row_bytes(),
                           kTileSize / 2);
    } catch (...) {
      CVPixelBufferUnlockBaseAddress(buffer.get(), 0);
      throw;
    }
    CVPixelBufferUnlockBaseAddress(buffer.get(), 0);
    attach_color(buffer.get(), params.color);

    VTEncodeInfoFlags flags = 0;
    check_status(VTCompressionSessionEncodeFrame(
                     session.get(), buffer.get(), CMTimeMake(static_cast<int64_t>(index), 1),
                     kCMTimeInvalid, frame_options.get(),
                     reinterpret_cast<void*>(static_cast<std::uintptr_t>(index)), &flags),
                 "submit HEVC picture");
    if (flags & kVTEncodeInfo_FrameDropped) throw VtError("VideoToolbox dropped an HEVC picture");
  }
  check_status(VTCompressionSessionCompleteFrames(session.get(), kCMTimeInvalid),
               "complete HEVC pictures");

  std::lock_guard lock(state.mutex);
  if (!state.error.empty()) throw VtError(state.error);
  for (std::size_t i = 0; i < count; ++i) {
    if (!state.present[i]) throw VtError("VideoToolbox did not return every HEVC picture");
  }
  EncodedSequence result;
  result.vps = std::move(state.sets.vps);
  result.sps = std::move(state.sets.sps);
  result.pps = std::move(state.sets.pps);
  result.samples = std::move(state.samples);
  if (audit) {
    audit->vps=result.vps;audit->sps=result.sps;audit->pps=result.pps;
    audit->samples=std::move(state.with_unspecified);
  }
  return result;
}

}  // namespace

EncodedSequence encode_sequence(std::size_t count, const TileProducer& produce,
                                const EncodeParams& params, bool invalidate_on_failure) {
  try {
    return run(count, produce, params);
  } catch (const VtError&) {
    if (invalidate_on_failure) invalidate_encoder_caps();
    throw;
  }
}

EncodedSequence encode(std::size_t count, const TileProducer& produce,
                       const EncodeParams& params) {
  return encode_sequence(count, produce, params, true);
}

EncodedSequence encode(std::span<const YuvTile> tiles, const EncodeParams& params) {
  return encode(tiles.size(), [&](std::size_t index, YuvTile& tile) {
    const auto& source = tiles[index];
    validate_tile(source, params.main10 ? 10 : 8);
    std::memcpy(tile.luma.data(), source.luma.data(), tile.luma.size());
    std::memcpy(tile.chroma.data(), source.chroma.data(), tile.chroma.size());
  }, params);
}

namespace testing {
AuditedSequence encode_audited(std::size_t count,const TileProducer& produce,const EncodeParams& params) {
  AuditedSequence result;result.filtered=run(count,produce,params,&result.with_unspecified);return result;
}
std::vector<std::uint8_t> repack_sample(const std::vector<std::uint8_t>& sample,int length_size,
    const EncodedSequence& sets) {
  return ::hyperdr::codec::hevc::repack_sample(sample,length_size,{sets.vps,sets.sps,sets.pps});
}
} // namespace testing

}  // namespace hyperdr::codec::hevc

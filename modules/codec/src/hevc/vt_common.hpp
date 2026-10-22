#pragma once

// Pieces shared by the VideoToolbox encoder, decoder and probe.

#include "hevc/hevc.hpp"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>

namespace hyperdr::codec::hevc {

// A VideoToolbox / CoreMedia call failed. Only this kind of failure says the
// encoder itself is unreliable, so only this one invalidates the probe cache.
class VtError : public std::runtime_error {
 public:
  VtError(const std::string& operation, OSStatus status)
      : std::runtime_error(operation + " failed (OSStatus " + std::to_string(status) + ")"),
        status_(status) {}
  explicit VtError(const std::string& message)
      : std::runtime_error(message), status_(0) {}
  [[nodiscard]] OSStatus status() const noexcept { return status_; }

 private:
  OSStatus status_;
};

inline void check_status(OSStatus status, const char* operation) {
  if (status != noErr) throw VtError(operation, status);
}

// Owns one +1 reference to a CoreFoundation object.
template <class T>
class CfRef {
 public:
  CfRef() = default;
  explicit CfRef(T ref) noexcept : ref_(ref) {}
  ~CfRef() { reset(); }
  CfRef(const CfRef&) = delete;
  CfRef& operator=(const CfRef&) = delete;
  CfRef(CfRef&& other) noexcept : ref_(std::exchange(other.ref_, nullptr)) {}
  CfRef& operator=(CfRef&& other) noexcept {
    if (this != &other) {
      reset();
      ref_ = std::exchange(other.ref_, nullptr);
    }
    return *this;
  }
  void reset() noexcept {
    if (ref_) CFRelease(ref_);
    ref_ = nullptr;
  }
  [[nodiscard]] T get() const noexcept { return ref_; }
  [[nodiscard]] T* out() noexcept {
    reset();
    return &ref_;
  }
  explicit operator bool() const noexcept { return ref_ != nullptr; }

 private:
  T ref_{};
};

[[nodiscard]] inline CfRef<CFNumberRef> cf_int(int value) {
  return CfRef<CFNumberRef>(CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value));
}

[[nodiscard]] inline CfRef<CFNumberRef> cf_float(float value) {
  return CfRef<CFNumberRef>(CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat32Type, &value));
}

[[nodiscard]] inline CfRef<CFMutableDictionaryRef> cf_dictionary() {
  return CfRef<CFMutableDictionaryRef>(CFDictionaryCreateMutable(
      kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
}

[[nodiscard]] inline OSType pixel_format(int bit_depth) {
  return bit_depth > 8 ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                       : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

// H.273 code points to CoreVideo's names. nullptr for "unspecified" (2); a
// value CoreVideo has no name for is a caller error.
CFStringRef cv_primaries(int code);
CFStringRef cv_transfer(int code);
CFStringRef cv_matrix(int code);
// And back; 2 when absent or unknown.
int h273_primaries(CFTypeRef value);
int h273_transfer(CFTypeRef value);
int h273_matrix(CFTypeRef value);

// HEVC NAL unit types the encoder handles by name.
enum : int {
  kNalIdrWRadl = 19,
  kNalIdrNLp = 20,
  kNalVps = 32,
  kNalSps = 33,
  kNalPps = 34,
  kNalAud = 35,
  kNalPrefixSei = 39,
  kNalSuffixSei = 40,
};

[[nodiscard]] inline int nal_type(const std::uint8_t* nal) { return (nal[0] >> 1) & 0x3F; }

// Copies one plane between a CVPixelBuffer and a tile, row by row with each
// side's own stride. The buffer must be locked.
void copy_plane_to_buffer(CVPixelBufferRef buffer, std::size_t plane, const std::uint8_t* source,
                          std::size_t row_bytes, std::size_t rows);
void copy_plane_from_buffer(CVPixelBufferRef buffer, std::size_t plane, std::uint8_t* destination,
                            std::size_t row_bytes, std::size_t rows);

// The encoder behind `encode`. The probe calls it with `invalidate_on_failure`
// off: it runs while holding the capabilities cache, and its failures are the
// answer rather than a reason to forget one.
EncodedSequence encode_sequence(std::size_t count, const TileProducer& produce,
                                const EncodeParams& params, bool invalidate_on_failure);

}  // namespace hyperdr::codec::hevc

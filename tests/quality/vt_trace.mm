// Opt-in laboratory interposer. Never linked or loaded by the product.
#include <CoreFoundation/CoreFoundation.h>
#include <VideoToolbox/VideoToolbox.h>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
static OSStatus create(CFAllocatorRef a, int32_t w, int32_t h,
                       CMVideoCodecType c, CFDictionaryRef spec,
                       CFDictionaryRef attrs, CFAllocatorRef alloc,
                       VTCompressionOutputCallback callback, void *ref,
                       VTCompressionSessionRef *out) {
  CFMutableDictionaryRef changed = nullptr;
  if (const auto v = std::getenv("HYPERDR_LAB_HARDWARE")) {
    changed = spec
                  ? CFDictionaryCreateMutableCopy(nullptr, 0, spec)
                  : CFDictionaryCreateMutable(nullptr, 0,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(
        changed,
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder,
        atoi(v) ? kCFBooleanTrue : kCFBooleanFalse);
    spec = changed;
  }
  const auto s = VTCompressionSessionCreate(a, w, h, c, spec, attrs, alloc,
                                            callback, ref, out);
  if (std::getenv("HYPERDR_LAB_TRACE")) {
    std::fprintf(stderr, "VT_CREATE %d %d status=%d\n", w, h, s);
    if (spec)
      CFShow(spec);
  }
  if (changed)
    CFRelease(changed);
  return s;
}
static void number(VTSessionRef s, CFStringRef k, const char *env) {
  if (const auto v = std::getenv(env)) {
    double n = atof(v);
    auto value = CFNumberCreate(nullptr, kCFNumberDoubleType, &n);
    auto r = VTSessionSetProperty(s, k, value);
    if (r)
      std::fprintf(stderr, "OVERRIDE_FAILURE %s %d\n", env, r);
    CFRelease(value);
  }
}
static void boolean(VTSessionRef s, CFStringRef k, const char *env) {
  if (const auto v = std::getenv(env)) {
    auto r =
        VTSessionSetProperty(s, k, atoi(v) ? kCFBooleanTrue : kCFBooleanFalse);
    if (r)
      std::fprintf(stderr, "OVERRIDE_FAILURE %s %d\n", env, r);
  }
}
static OSStatus prepare(VTCompressionSessionRef s) {
  CFTypeRef transfer = nullptr;
  VTSessionCopyProperty(s, kVTCompressionPropertyKey_TransferFunction, nullptr,
                        &transfer);
  number(s, kVTCompressionPropertyKey_Quality,
         transfer ? "HYPERDR_LAB_QUALITY" : "HYPERDR_LAB_GAIN_QUALITY");
  if (transfer)
    CFRelease(transfer);
  number(s, kVTCompressionPropertyKey_ExpectedFrameRate, "HYPERDR_LAB_FPS");
  number(s, kVTCompressionPropertyKey_MaxFrameDelayCount, "HYPERDR_LAB_DELAY");
  number(s, kVTCompressionPropertyKey_ConstantBitRate, "HYPERDR_LAB_CBR");
  boolean(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
          "HYPERDR_LAB_SPEED");
  boolean(s, kVTCompressionPropertyKey_AllowFrameReordering,
          "HYPERDR_LAB_REORDER");
  const auto result = VTCompressionSessionPrepareToEncodeFrames(s);
  if (std::getenv("HYPERDR_LAB_TRACE")) {
    CFDictionaryRef properties = nullptr;
    const auto copyStatus =
        VTSessionCopySerializableProperties(s, nullptr, &properties);
    std::fprintf(stderr, "VT_PREPARE status=%d serializable=%d\n", result,
                 copyStatus);
    for (auto key :
         {kVTCompressionPropertyKey_Quality,
          kVTCompressionPropertyKey_AverageBitRate,
          kVTCompressionPropertyKey_ConstantBitRate,
          kVTCompressionPropertyKey_ExpectedFrameRate,
          kVTCompressionPropertyKey_ProfileLevel,
          kVTCompressionPropertyKey_AllowFrameReordering,
          kVTCompressionPropertyKey_MaxKeyFrameInterval,
          kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
          kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder}) {
      CFTypeRef value = nullptr;
      const auto status = VTSessionCopyProperty(s, key, nullptr, &value);
      CFShow(key);
      std::fprintf(stderr, "status=%d\n", status);
      if (value) {
        CFShow(value);
        CFRelease(value);
      }
    }
    if (properties) {
      CFShow(properties);
      CFRelease(properties);
    }
  }
  return result;
}
#define INTERPOSE(replacement, original)                                       \
  __attribute__((used)) static struct {                                        \
    const void *r;                                                             \
    const void *o;                                                             \
  } interpose_##replacement __attribute__((section("__DATA,__interpose"))) = { \
      (const void *)&replacement, (const void *)&original};
INTERPOSE(create, VTCompressionSessionCreate)
INTERPOSE(prepare, VTCompressionSessionPrepareToEncodeFrames)

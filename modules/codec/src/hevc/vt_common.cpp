#include "hevc/vt_common.hpp"

#include <cstring>

namespace hyperdr::codec::hevc {
namespace {

bool same(CFTypeRef value, CFStringRef name) {
  return value && CFGetTypeID(value) == CFStringGetTypeID() &&
         CFStringCompare(static_cast<CFStringRef>(value), name, 0) == kCFCompareEqualTo;
}

void check_plane(CVPixelBufferRef buffer, std::size_t plane, std::size_t row_bytes,
                 std::size_t rows) {
  if (CVPixelBufferGetPlaneCount(buffer) != 2) throw VtError("pixel buffer is not bi-planar");
  if (CVPixelBufferGetHeightOfPlane(buffer, plane) != rows ||
      CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) < row_bytes ||
      !CVPixelBufferGetBaseAddressOfPlane(buffer, plane)) {
    throw VtError("pixel buffer plane has an unexpected layout");
  }
}

}  // namespace

CFStringRef cv_primaries(int code) {
  switch (code) {
    case 2: return nullptr;
    case 1: return kCVImageBufferColorPrimaries_ITU_R_709_2;
    case 9: return kCVImageBufferColorPrimaries_ITU_R_2020;
    case 12: return kCVImageBufferColorPrimaries_P3_D65;
    default: throw std::invalid_argument("unsupported HEVC colour primaries");
  }
}

CFStringRef cv_transfer(int code) {
  switch (code) {
    case 2: return nullptr;
    case 1: return kCVImageBufferTransferFunction_ITU_R_709_2;
    case 8: return kCVImageBufferTransferFunction_Linear;
    case 13: return kCVImageBufferTransferFunction_sRGB;
    case 16: return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    case 18: return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    default: throw std::invalid_argument("unsupported HEVC transfer characteristics");
  }
}

CFStringRef cv_matrix(int code) {
  switch (code) {
    case 2: return nullptr;
    case 1: return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    case 9: return kCVImageBufferYCbCrMatrix_ITU_R_2020;
    default: throw std::invalid_argument("unsupported HEVC matrix coefficients");
  }
}

int h273_primaries(CFTypeRef value) {
  for (const int code : {1, 9, 12}) {
    if (same(value, cv_primaries(code))) return code;
  }
  return 2;
}

int h273_transfer(CFTypeRef value) {
  for (const int code : {1, 8, 13, 16, 18}) {
    if (same(value, cv_transfer(code))) return code;
  }
  return 2;
}

int h273_matrix(CFTypeRef value) {
  for (const int code : {1, 9}) {
    if (same(value, cv_matrix(code))) return code;
  }
  return 2;
}

void copy_plane_to_buffer(CVPixelBufferRef buffer, std::size_t plane, const std::uint8_t* source,
                          std::size_t row_bytes, std::size_t rows) {
  check_plane(buffer, plane, row_bytes, rows);
  auto* base = static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, plane));
  const std::size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
  for (std::size_t y = 0; y < rows; ++y) {
    std::memcpy(base + y * stride, source + y * row_bytes, row_bytes);
  }
}

void copy_plane_from_buffer(CVPixelBufferRef buffer, std::size_t plane, std::uint8_t* destination,
                            std::size_t row_bytes, std::size_t rows) {
  check_plane(buffer, plane, row_bytes, rows);
  const auto* base =
      static_cast<const std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(buffer, plane));
  const std::size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
  for (std::size_t y = 0; y < rows; ++y) {
    std::memcpy(destination + y * row_bytes, base + y * stride, row_bytes);
  }
}

}  // namespace hyperdr::codec::hevc

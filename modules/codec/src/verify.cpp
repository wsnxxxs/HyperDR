// Decode-verification for whatever an encoding just wrote.
//
// The per-format checks live beside their encoders; this is the one dispatch
// that turns "the format I asked for" into "the check that proves the file
// opens". It is shared by the converter and by the packaging entry point so an
// export cannot be published unverified because two call sites drifted.

#include "hyperdr/codec/encoders.hpp"

// The codec-less build defines this entry point in unavailable.cpp instead,
// where every other encoder is a "needs codecs" failure.
#if HYPERDR_WITH_CODECS

namespace hyperdr {

void verify_encoded_output(std::span<const std::uint8_t> bytes,
                           HdrEncoding encoding) {
  if (encoding == HdrEncoding::SdrTiff) verify_sdr_tiff(bytes);
  else if (encoding == HdrEncoding::SdrJpeg) verify_sdr_jpeg(bytes);
  else if (encoding == HdrEncoding::IsoGainMapJpeg) verify_gain_map_jpeg(bytes);
  else if (is_avif_encoding(encoding)) verify_avif_decodable(bytes);
  else verify_heic_decodable(bytes, encoding);
}

}  // namespace hyperdr

#endif  // HYPERDR_WITH_CODECS

#if HYPERDR_WITH_CODECS
#include "internal/verify_pixels.hpp"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <system_error>
namespace hyperdr {
namespace {
class VerificationFile {
  void* mapping=MAP_FAILED;
  std::size_t size=0;
 public:
  explicit VerificationFile(const std::filesystem::path& path) {
    const int fd=::open(path.c_str(),O_RDONLY);
    if(fd<0)throw std::system_error(errno,std::generic_category(),"open verification file");
    struct stat info{};
    if(fstat(fd,&info)!=0||info.st_size<=0) { const int error=errno;::close(fd);throw std::system_error(error?error:EINVAL,std::generic_category(),"stat verification file"); }
    size=std::size_t(info.st_size);mapping=mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);
    const int error=errno;::close(fd);
    if(mapping==MAP_FAILED)throw std::system_error(error,std::generic_category(),"map verification file");
    // File-backed pages are reclaimable, not a private encoded-file vector.
    madvise(mapping,size,MADV_SEQUENTIAL);
  }
  ~VerificationFile() { if(mapping!=MAP_FAILED)munmap(mapping,size); }
  std::span<const std::uint8_t> bytes()const{return {static_cast<const std::uint8_t*>(mapping),size};}
};
}
VerificationResult verify_encoded_file(const std::filesystem::path& path,HdrEncoding encoding,
                                       std::optional<VerificationFrame> frame) {
  VerificationFile file(path);
  const auto bytes=file.bytes();
  if(encoding==HdrEncoding::SdrTiff) {
    if(frame)throw std::invalid_argument("SDR TIFF has no gain-map frame");
    return codec::verify_tiff_pixels(bytes);
  }
  if(encoding==HdrEncoding::SdrJpeg||encoding==HdrEncoding::IsoGainMapJpeg)
    return codec::verify_jpeg_pixels(bytes,encoding==HdrEncoding::IsoGainMapJpeg,frame);
  if(is_avif_encoding(encoding)) {
    if(frame)throw std::invalid_argument("AVIF has no gain-map frame");
    return verify_avif_pixels(bytes);
  }
  return codec::verify_heif_pixels(bytes,encoding,frame);
}
} // namespace hyperdr
#endif

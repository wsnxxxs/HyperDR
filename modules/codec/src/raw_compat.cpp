#include "hyperdr/codec/raw_compat.hpp"

#include "internal/raw_compat_internal.hpp"

#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"

#include <libraw/libraw.h>
#include <tiffio.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <limits>
#include <memory>
#include <numeric>
#include <optional>
#include <span>
#include <string>
#include <system_error>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

// The upstream 0.22.2 release does not contain the ILCE-7M5 colour table.
// This snapshot also includes the current Sony ARW6 decoder. Bump dng-2 when
// the serialization (not merely the LibRaw snapshot) changes.
constexpr char kConverterId[] = "libraw-0.22.0+2caab57e/dng-2";
constexpr std::uint16_t kPhotometricLinearRaw = 34892;

std::string bounded_text(const char* value, std::size_t capacity) {
  if (!value) return {};
  std::size_t size = 0;
  while (size < capacity && value[size]) ++size;
  return std::string(value, size);
}

std::string camera_name(const LibRaw& raw) {
  const auto make = bounded_text(raw.imgdata.idata.make, sizeof(raw.imgdata.idata.make));
  const auto model = bounded_text(raw.imgdata.idata.model, sizeof(raw.imgdata.idata.model));
  if (make.empty()) return model;
  if (model.empty()) return make;
  if (model.size() >= make.size()) {
    const auto insensitive = [](unsigned char c) {
      return c >= 'A' && c <= 'Z' ? static_cast<unsigned char>(c + ('a' - 'A')) : c;
    };
    bool prefixed = true;
    for (std::size_t i = 0; i < make.size(); ++i) {
      prefixed = prefixed && insensitive(make[i]) == insensitive(model[i]);
    }
    if (prefixed) return model;
  }
  return make + " " + model;
}

[[noreturn]] void unsupported(const LibRaw& raw) {
  throw RawUnsupported("camera", camera_name(raw));
}

void check_raw(int code, const LibRaw& raw, const char* operation) {
  check_cancelled();
  if (code == LIBRAW_SUCCESS) return;
  if (code == LIBRAW_CANCELLED_BY_CALLBACK) throw Cancelled();
  if (code == LIBRAW_UNSUFFICIENT_MEMORY || code == LIBRAW_MEMPOOL_OVERFLOW || code == ENOMEM) {
    throw RawMemoryError(std::string(operation) + ": insufficient memory");
  }
  // The compatibility entry deliberately uses one public error for a file
  // LibRaw cannot identify, unpack or calibrate. In particular, never invent a
  // colour matrix just to get an apparently usable DNG out of an unknown camera.
  static_cast<void>(operation);
  unsupported(raw);
}

int progress_callback(void* data, LibRaw_progress, int, int) {
  const auto* token = static_cast<const CancelToken*>(data);
  return token && token->requested() ? 1 : 0;
}

class RawFile final : public LibRaw {
 public:
  RawFile() {
    set_progress_handler(progress_callback, const_cast<CancelToken*>(current_cancel_token));
    set_exifparser_handler(read_capture_tags, this);
  }

  std::optional<double> exposure_bias;
  std::uint32_t exif_width = 0, exif_height = 0;

 private:
  static void read_capture_tags(void* context, int tag, int type, int len,
                                unsigned int order, void* input, INT64) {
    // LibRaw does not expose ExposureBiasValue or the developed dimensions.
    // Its callback is positioned at the value and must be left there on return.
    if (tag != 0x9204 && tag != 0xa002 && tag != 0xa003) return;
    if (tag == 0x9204 && (len < 1 || (type != 5 && type != 10))) return;
    if (tag != 0x9204 && (len < 1 || (type != 3 && type != 4))) return;
    auto* stream = static_cast<LibRaw_abstract_datastream*>(input);
    const auto position = stream->tell();
    std::uint8_t bytes[8]{};
    const std::size_t needed = tag == 0x9204 ? 8 : type == 3 ? 2 : 4;
    const auto count = stream->read(bytes, 1, needed);
    stream->seek(position, SEEK_SET);
    if (count != static_cast<int>(needed)) return;
    const bool little = order == 0x4949;
    const auto u16 = [&](std::size_t at) -> std::uint16_t {
      return little ? static_cast<std::uint16_t>(bytes[at] | (bytes[at + 1] << 8U))
                    : static_cast<std::uint16_t>((bytes[at] << 8U) | bytes[at + 1]);
    };
    const auto u32 = [&](std::size_t at) -> std::uint32_t {
      if (little) {
        return static_cast<std::uint32_t>(bytes[at]) |
               (static_cast<std::uint32_t>(bytes[at + 1]) << 8U) |
               (static_cast<std::uint32_t>(bytes[at + 2]) << 16U) |
               (static_cast<std::uint32_t>(bytes[at + 3]) << 24U);
      }
      return (static_cast<std::uint32_t>(bytes[at]) << 24U) |
             (static_cast<std::uint32_t>(bytes[at + 1]) << 16U) |
             (static_cast<std::uint32_t>(bytes[at + 2]) << 8U) |
             static_cast<std::uint32_t>(bytes[at + 3]);
    };
    if (tag != 0x9204) {
      const std::uint32_t value = type == 3 ? u16(0) : u32(0);
      if (tag == 0xa002) static_cast<RawFile*>(context)->exif_width = value;
      else static_cast<RawFile*>(context)->exif_height = value;
      return;
    }
    const auto numerator = static_cast<std::int32_t>(u32(0));
    const auto denominator = u32(4);
    if (!denominator) return;
    const double value = static_cast<double>(numerator) / denominator;
    if (std::isfinite(value)) static_cast<RawFile*>(context)->exposure_bias = value;
  }
};

std::unique_ptr<RawFile> opened_raw(const std::filesystem::path& path) {
  check_cancelled();
  auto raw = std::make_unique<RawFile>();
  auto& params = raw->imgdata.params;
  // LinearRaw processing is camera RGB only: no output colour transform, no
  // gamma and no automatic brightness. Keeping scale_colors off also leaves
  // white balance to AsShotNeutral instead of baking it into the samples.
  params.output_color = 0;
  params.output_bps = 16;
  params.gamm[0] = 1.0;
  params.gamm[1] = 1.0;
  params.no_auto_bright = 1;
  params.no_auto_scale = 1;
  params.use_camera_wb = 0;
  params.use_auto_wb = 0;
  params.use_camera_matrix = 1;
  params.highlight = 0;
  params.med_passes = 0;
  params.half_size = 0;
  params.use_fuji_rotate = 0;
  params.adjust_maximum_thr = 0.0F;
  check_raw(raw->open_file(path.c_str()), *raw, "LibRaw open");
  check_cancelled();
  return raw;
}

std::uint16_t orientation_from_flip(int flip) {
  // LibRaw's flip bits and EXIF orientation use different numberings. This is
  // the inverse of LibRaw's TIFF mapping "50132467"[orientation & 7].
  constexpr std::array<std::uint16_t, 8> orientations{{1, 2, 4, 3, 5, 8, 6, 7}};
  return orientations[static_cast<unsigned>(flip) & 7U];
}

struct Crop {
  std::uint32_t left{}, top{}, width{}, height{};
};

Crop default_crop(const RawFile& raw) {
  const auto& sizes = raw.imgdata.sizes;
  const std::uint64_t raw_width = sizes.raw_width ? sizes.raw_width : sizes.width;
  const std::uint64_t raw_height = sizes.raw_height ? sizes.raw_height : sizes.height;
  const Crop visible{sizes.left_margin, sizes.top_margin, sizes.width, sizes.height};
  Crop crop = visible;
  const auto& inset = sizes.raw_inset_crops[0];
  const bool has_inset = inset.cleft != 0xffff && inset.ctop != 0xffff && inset.cwidth && inset.cheight;
  if (has_inset) {
    crop = {inset.cleft, inset.ctop, inset.cwidth, inset.cheight};
  } else if (raw.exif_width && raw.exif_height &&
             raw.exif_width <= visible.width && raw.exif_height <= visible.height &&
             std::uint64_t(raw.exif_width) * 10 >= std::uint64_t(visible.width) * 9 &&
             std::uint64_t(raw.exif_height) * 10 >= std::uint64_t(visible.height) * 9) {
    // Some native formats record the developed dimensions only in EXIF. Use
    // them when they clearly describe the full photograph (not an embedded
    // preview), and centre the tighter crop on LibRaw's visible sensor area.
    crop.width = raw.exif_width;
    crop.height = raw.exif_height;
    crop.left = visible.left + ((visible.width - crop.width) / 2U & ~1U);
    crop.top = visible.top + ((visible.height - crop.height) / 2U & ~1U);
  }
  if (!raw_width || !raw_height || !crop.width || !crop.height ||
      crop.left < visible.left || crop.top < visible.top ||
      static_cast<std::uint64_t>(crop.left) + crop.width >
          static_cast<std::uint64_t>(visible.left) + visible.width ||
      static_cast<std::uint64_t>(crop.top) + crop.height >
          static_cast<std::uint64_t>(visible.top) + visible.height ||
      crop.left >= raw_width || crop.top >= raw_height ||
      static_cast<std::uint64_t>(crop.left) + crop.width > raw_width ||
      static_cast<std::uint64_t>(crop.top) + crop.height > raw_height) {
    unsupported(raw);
  }
  return crop;
}

using ColorMatrix = std::array<float, 9>;

ColorMatrix color_matrix(const RawFile& raw) {
  const auto& color = raw.imgdata.color;
  bool has_cam_xyz = false;
  for (const auto& row : color.cam_xyz) {
    for (const float value : row) {
      if (!std::isfinite(value)) unsupported(raw);
      has_cam_xyz = has_cam_xyz || value != 0.0F;
    }
  }

  if (!has_cam_xyz) unsupported(raw);
  ColorMatrix matrix{};
  // cam_xyz_coeff already produces DNG's XYZ D65 -> camera matrix: camera
  // channel rows by XYZ columns. In particular, do not transpose or invert it.
  for (unsigned channel = 0; channel < 3; ++channel) {
    for (unsigned xyz = 0; xyz < 3; ++xyz) {
      matrix[channel * 3 + xyz] = color.cam_xyz[channel][xyz];
    }
  }
  for (const float value : matrix) if (!std::isfinite(value)) unsupported(raw);
  const auto& m = matrix;
  const double determinant =
      static_cast<double>(m[0]) * (m[4] * m[8] - m[5] * m[7]) -
      static_cast<double>(m[1]) * (m[3] * m[8] - m[5] * m[6]) +
      static_cast<double>(m[2]) * (m[3] * m[7] - m[4] * m[6]);
  if (!std::isfinite(determinant) || std::abs(determinant) < 1.0e-10) unsupported(raw);
  return matrix;
}

std::optional<std::array<float, 3>> as_shot_neutral(const RawFile& raw) {
  std::array<float, 3> neutral{};
  for (unsigned c = 0; c < 3; ++c) {
    const float multiplier = raw.imgdata.color.cam_mul[c];
    if (!(std::isfinite(multiplier) && multiplier > 0.0F)) return std::nullopt;
    neutral[c] = 1.0F / multiplier;
  }
  const float green = neutral[1];
  if (!(std::isfinite(green) && green > 0.0F)) return std::nullopt;
  for (float& value : neutral) value /= green;
  return neutral;
}

std::string capture_time(const RawFile& raw) {
  const time_t timestamp = raw.imgdata.other.timestamp;
  if (timestamp <= 0) return {};
  std::tm broken_down{};
  if (!localtime_r(&timestamp, &broken_down)) return {};
  char text[20]{};
  if (!std::strftime(text, sizeof(text), "%Y:%m:%d %H:%M:%S", &broken_down)) return {};
  return text;
}

class AtomicOutput {
 public:
  explicit AtomicOutput(std::filesystem::path output) : output_(std::move(output)) {
    struct stat info {};
    if (::lstat(output_.c_str(), &info) == 0) {
      throw std::runtime_error("output exists: " + path_utf8(output_));
    }
    if (errno != ENOENT) throw std::system_error(errno, std::generic_category(), "cannot inspect output");
    if (output_.has_parent_path()) std::filesystem::create_directories(output_.parent_path());
    static std::atomic<std::uint64_t> sequence{0};
    for (unsigned attempt = 0; attempt < 256; ++attempt) {
      temporary_ = output_;
      temporary_ += ".tmp." + std::to_string(::getpid()) + "." +
                    std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
      descriptor_ = ::open(temporary_.c_str(), O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
      if (descriptor_ >= 0) {
#ifdef F_NOCACHE
        static_cast<void>(::fcntl(descriptor_, F_NOCACHE, 1));
#endif
        return;
      }
      if (errno != EEXIST) {
        throw std::system_error(errno, std::generic_category(), "cannot create RAW compatibility output");
      }
    }
    throw std::runtime_error("cannot find a free temporary output name");
  }

  ~AtomicOutput() {
    if (descriptor_ >= 0) ::close(descriptor_);
    if (!temporary_.empty()) ::unlink(temporary_.c_str());
    if (published_ && !committed_) ::unlink(output_.c_str());
  }
  AtomicOutput(const AtomicOutput&) = delete;
  AtomicOutput& operator=(const AtomicOutput&) = delete;

  int descriptor() const { return descriptor_; }
  int take_descriptor() { return std::exchange(descriptor_, -1); }
  const std::filesystem::path& temporary_path() const { return temporary_; }

  void sync_and_close() {
    if (descriptor_ < 0) return;
    check_cancelled();
    if (::fsync(descriptor_) != 0) {
      throw std::system_error(errno, std::generic_category(), "cannot flush RAW compatibility output");
    }
    if (::close(descriptor_) != 0) {
      descriptor_ = -1;
      throw std::system_error(errno, std::generic_category(), "cannot close RAW compatibility output");
    }
    descriptor_ = -1;
  }

  void publish() {
    if (descriptor_ >= 0) sync_and_close();
    check_cancelled();
    if (::renameatx_np(AT_FDCWD, temporary_.c_str(), AT_FDCWD, output_.c_str(), RENAME_EXCL) != 0) {
      if (errno == EEXIST) throw std::runtime_error("output exists: " + path_utf8(output_));
      throw std::system_error(errno, std::generic_category(), "cannot publish RAW compatibility output");
    }
    temporary_.clear();
    published_ = true;
    const auto directory = output_.has_parent_path() ? output_.parent_path() : std::filesystem::path(".");
    const int parent = ::open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (parent < 0) throw std::system_error(errno, std::generic_category(), "cannot open output directory");
    const int result = ::fsync(parent);
    const int error = errno;
    ::close(parent);
    if (result != 0) throw std::system_error(error, std::generic_category(), "cannot flush output directory");
    committed_ = true;
  }

 private:
  std::filesystem::path output_, temporary_;
  int descriptor_ = -1;
  bool published_ = false, committed_ = false;
};

void write_all(int descriptor, const std::uint8_t* bytes, std::size_t size) {
  while (size) {
    check_cancelled();
    const auto count = ::write(descriptor, bytes, std::min<std::size_t>(size, 1U << 20U));
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      throw std::system_error(count < 0 ? errno : EIO, std::generic_category(),
                              "cannot write embedded RAW preview");
    }
    bytes += count;
    size -= static_cast<std::size_t>(count);
  }
}

struct TiffCloser { void operator()(TIFF* tiff) const { if (tiff) TIFFClose(tiff); } };
using TiffHandle = std::unique_ptr<TIFF, TiffCloser>;

void require_tiff(int result) {
  if (!result) throw std::runtime_error("cannot serialize DNG metadata");
}

void write_exif(TIFF* tiff, const RawFile& raw, const std::string& date_time) {
  require_tiff(TIFFCreateEXIFDirectory(tiff) == 0);
  const std::uint8_t version[4] = {'0', '2', '3', '0'};
  require_tiff(TIFFSetField(tiff, EXIFTAG_EXIFVERSION, version));
  const auto& other = raw.imgdata.other;
  if (!date_time.empty()) require_tiff(TIFFSetField(tiff, EXIFTAG_DATETIMEORIGINAL, date_time.c_str()));
  if (std::isfinite(other.iso_speed) && other.iso_speed > 0.0F) {
    const std::uint16_t iso[1] = {static_cast<std::uint16_t>(std::min(65535.0F, other.iso_speed))};
    require_tiff(TIFFSetField(tiff, EXIFTAG_ISOSPEEDRATINGS, 1, iso));
  }
  if (std::isfinite(other.shutter) && other.shutter > 0.0F) {
    require_tiff(TIFFSetField(tiff, EXIFTAG_EXPOSURETIME, static_cast<double>(other.shutter)));
  }
  if (std::isfinite(other.aperture) && other.aperture > 0.0F) {
    require_tiff(TIFFSetField(tiff, EXIFTAG_FNUMBER, static_cast<double>(other.aperture)));
  }
  if (raw.exposure_bias) {
    require_tiff(TIFFSetField(tiff, EXIFTAG_EXPOSUREBIASVALUE, static_cast<double>(*raw.exposure_bias)));
  }
  if (std::isfinite(other.focal_len) && other.focal_len > 0.0F) {
    require_tiff(TIFFSetField(tiff, EXIFTAG_FOCALLENGTH, static_cast<double>(other.focal_len)));
  }
  float focal35 = raw.imgdata.lens.FocalLengthIn35mmFormat;
  if (!(focal35 > 0.0F)) focal35 = raw.imgdata.lens.makernotes.FocalLengthIn35mmFormat;
  if (std::isfinite(focal35) && focal35 > 0.0F) {
    require_tiff(TIFFSetField(tiff, EXIFTAG_FOCALLENGTHIN35MMFILM,
                              static_cast<std::uint16_t>(std::clamp(std::lround(focal35), 1L, 65535L))));
  }
  auto lens = bounded_text(raw.imgdata.lens.Lens, sizeof(raw.imgdata.lens.Lens));
  if (lens.empty()) {
    lens = bounded_text(raw.imgdata.lens.makernotes.Lens, sizeof(raw.imgdata.lens.makernotes.Lens));
  }
  if (!lens.empty()) require_tiff(TIFFSetField(tiff, EXIFTAG_LENSMODEL, lens.c_str()));

  std::uint64_t offset = 0;
  require_tiff(TIFFWriteCustomDirectory(tiff, &offset));
  require_tiff(TIFFSetDirectory(tiff, 0));
  require_tiff(TIFFSetField(tiff, TIFFTAG_EXIFIFD, offset));
}

void common_metadata(TIFF* tiff, const RawFile& raw, const Crop& crop,
                     const ColorMatrix& matrix, const std::string& date_time,
                     bool linear_raw = false) {
  const std::uint8_t version[4] = {1, 4, 0, 0}, backward[4] = {1, 1, 0, 0};
  require_tiff(TIFFSetField(tiff, TIFFTAG_SUBFILETYPE, 0U));
  require_tiff(TIFFSetField(tiff, TIFFTAG_DNGVERSION, version));
  require_tiff(TIFFSetField(tiff, TIFFTAG_DNGBACKWARDVERSION, backward));
  const auto make = bounded_text(raw.imgdata.idata.make, sizeof(raw.imgdata.idata.make));
  const auto model = bounded_text(raw.imgdata.idata.model, sizeof(raw.imgdata.idata.model));
  auto unique = bounded_text(raw.imgdata.color.UniqueCameraModel,
                            sizeof(raw.imgdata.color.UniqueCameraModel));
  if (unique.empty()) unique = camera_name(raw);
  if (unique.empty()) unsupported(raw);
  if (!make.empty()) require_tiff(TIFFSetField(tiff, TIFFTAG_MAKE, make.c_str()));
  if (!model.empty()) require_tiff(TIFFSetField(tiff, TIFFTAG_MODEL, model.c_str()));
  require_tiff(TIFFSetField(tiff, TIFFTAG_UNIQUECAMERAMODEL, unique.c_str()));
  require_tiff(TIFFSetField(tiff, TIFFTAG_SOFTWARE, "HyperDR LibRaw DNG compatibility"));
  require_tiff(TIFFSetField(tiff, TIFFTAG_ORIENTATION, orientation_from_flip(raw.imgdata.sizes.flip)));
  if (!date_time.empty()) require_tiff(TIFFSetField(tiff, TIFFTAG_DATETIME, date_time.c_str()));

  const auto& sensor = raw.imgdata.sizes;
  const std::uint32_t active[4] = {linear_raw ? 0U : sensor.top_margin,
      linear_raw ? 0U : sensor.left_margin,
      linear_raw ? sensor.iheight : static_cast<std::uint32_t>(sensor.top_margin + sensor.height),
      linear_raw ? sensor.iwidth : static_cast<std::uint32_t>(sensor.left_margin + sensor.width)};
  // DNG DefaultCropOrigin is relative to ActiveArea. LinearRaw's crop was
  // already rebased to its visible output; CFA still uses sensor coordinates.
  const float origin[2] = {
      static_cast<float>(crop.left - (linear_raw ? 0U : sensor.left_margin)),
      static_cast<float>(crop.top - (linear_raw ? 0U : sensor.top_margin))};
  const float size[2] = {static_cast<float>(crop.width), static_cast<float>(crop.height)};
  require_tiff(TIFFSetField(tiff, TIFFTAG_ACTIVEAREA, active));
  require_tiff(TIFFSetField(tiff, TIFFTAG_DEFAULTCROPORIGIN, origin));
  require_tiff(TIFFSetField(tiff, TIFFTAG_DEFAULTCROPSIZE, size));
  const float scale[2] = {1.0F, 1.0F};
  require_tiff(TIFFSetField(tiff, TIFFTAG_DEFAULTSCALE, scale));
  require_tiff(TIFFSetField(tiff, TIFFTAG_COLORMATRIX1, 9, matrix.data()));
  require_tiff(TIFFSetField(tiff, TIFFTAG_CALIBRATIONILLUMINANT1, 21));  // D65
  if (const auto neutral = as_shot_neutral(raw)) {
    require_tiff(TIFFSetField(tiff, TIFFTAG_ASSHOTNEUTRAL, 3, neutral->data()));
  }
  const float baseline = raw.imgdata.color.dng_levels.baseline_exposure;
  if (std::isfinite(baseline) && baseline > -999.0F) {
    require_tiff(TIFFSetField(tiff, TIFFTAG_BASELINEEXPOSURE, static_cast<double>(baseline)));
  }
}

bool bayer_pattern_impl(const LibRaw& raw, std::array<std::uint8_t, 4>* output = nullptr) {
  if (raw.imgdata.idata.filters <= 1000 || const_cast<LibRaw&>(raw).is_fuji_rotated() ||
      raw.imgdata.sizes.raw_width < 8 || raw.imgdata.sizes.raw_height < 8) return false;
  const auto role = [&](unsigned x, unsigned y) -> char {
    const int index = const_cast<LibRaw&>(raw).COLOR(static_cast<int>(y), static_cast<int>(x));
    return index >= 0 && index < 5 ? raw.imgdata.idata.cdesc[index] : '\0';
  };
  std::array<char, 4> pattern{{role(0, 0), role(1, 0), role(0, 1), role(1, 1)}};
  for (unsigned y = 0; y < 8; ++y) {
    for (unsigned x = 0; x < 2; ++x) {
      if (role(x, y) != pattern[(y & 1U) * 2 + x]) return false;
    }
  }
  static constexpr std::array<std::array<char, 4>, 4> bayer{{
      {{'R', 'G', 'G', 'B'}}, {{'B', 'G', 'G', 'R'}},
      {{'G', 'R', 'B', 'G'}}, {{'G', 'B', 'R', 'G'}}}};
  if (std::find(bayer.begin(), bayer.end(), pattern) == bayer.end()) return false;
  if (output) {
    for (unsigned i = 0; i < 4; ++i) {
      (*output)[i] = pattern[i] == 'R' ? 0 : pattern[i] == 'B' ? 2 : 1;
    }
  }
  return true;
}

void write_cfa(TIFF* tiff, RawFile& raw, const Crop& crop,
               const ColorMatrix& matrix, const std::string& date_time) {
  const auto& sizes = raw.imgdata.sizes;
  const auto& data = raw.imgdata.rawdata;
  if (!data.raw_image || !data.raw_alloc) unsupported(raw);
  const std::size_t pitch = sizes.raw_pitch ? sizes.raw_pitch : std::size_t(sizes.raw_width) * 2;
  if (pitch < std::size_t(sizes.raw_width) * 2 || (pitch & 1U)) unsupported(raw);
  const auto* pixels = reinterpret_cast<const std::uint16_t*>(data.raw_image);
  std::array<std::uint8_t, 4> cfa{};
  if (!raw_compat_internal::bayer_pattern(raw, &cfa)) unsupported(raw);

  require_tiff(TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, sizes.raw_width));
  require_tiff(TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, sizes.raw_height));
  require_tiff(TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 1));
  require_tiff(TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, 16));
  require_tiff(TIFFSetField(tiff, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT));
  require_tiff(TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_CFA));
  require_tiff(TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG));
  require_tiff(TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE));
  require_tiff(TIFFSetField(tiff, TIFFTAG_ROWSPERSTRIP, 16U));
  const std::uint16_t dimensions[2] = {2, 2};
  const std::uint8_t plane_colors[3] = {0, 1, 2};
  require_tiff(TIFFSetField(tiff, TIFFTAG_CFAREPEATPATTERNDIM, dimensions));
  require_tiff(TIFFSetField(tiff, TIFFTAG_CFAPATTERN, 4, cfa.data()));
  require_tiff(TIFFSetField(tiff, TIFFTAG_CFAPLANECOLOR, 3, plane_colors));
  require_tiff(TIFFSetField(tiff, TIFFTAG_CFALAYOUT, 1));
  common_metadata(tiff, raw, crop, matrix, date_time);

  const auto& color = raw.imgdata.color;
  const bool tiled = color.cblack[4] && color.cblack[5];
  const unsigned source_rows = tiled ? color.cblack[4] : 1;
  const unsigned source_columns = tiled ? color.cblack[5] : 1;
  const std::uint64_t source_count = std::uint64_t(source_rows) * source_columns;
  if (tiled && (!source_count || source_count > LIBRAW_CBLACK_SIZE - 6U)) unsupported(raw);
  const unsigned repeat_rows = std::lcm(source_rows, 2U);
  const unsigned repeat_columns = std::lcm(source_columns, 2U);
  const std::uint64_t repeat_count = std::uint64_t(repeat_rows) * repeat_columns;
  if (!repeat_count || repeat_count > 65536 || repeat_rows > 65535 || repeat_columns > 65535) unsupported(raw);
  std::vector<float> black(static_cast<std::size_t>(repeat_count));
  for (unsigned y = 0; y < repeat_rows; ++y) {
    for (unsigned x = 0; x < repeat_columns; ++x) {
      const int channel = raw.COLOR(static_cast<int>(y), static_cast<int>(x));
      if (channel < 0 || channel > 3) unsupported(raw);
      std::uint64_t value = color.black + color.cblack[channel];
      if (tiled) value += color.cblack[6 + (y % source_rows) * source_columns + (x % source_columns)];
      if (value > 1000000) unsupported(raw);
      black[std::size_t(y) * repeat_columns + x] = static_cast<float>(value);
    }
  }
  const std::uint16_t black_dimensions[2] = {
      static_cast<std::uint16_t>(repeat_rows), static_cast<std::uint16_t>(repeat_columns)};
  require_tiff(TIFFSetField(tiff, TIFFTAG_BLACKLEVELREPEATDIM, black_dimensions));
  require_tiff(TIFFSetField(tiff, TIFFTAG_BLACKLEVEL,
                            static_cast<std::uint32_t>(black.size()), black.data()));
  const std::uint32_t white[1] = {color.maximum};
  if (!color.maximum) unsupported(raw);
  require_tiff(TIFFSetField(tiff, TIFFTAG_WHITELEVEL, 1, white));

  const std::size_t stride = pitch / 2;
  for (unsigned y = 0; y < sizes.raw_height; ++y) {
    check_cancelled();
    if (TIFFWriteScanline(tiff, const_cast<std::uint16_t*>(pixels + std::size_t(y) * stride), y) < 0) {
      throw std::runtime_error("cannot write CFA DNG samples");
    }
  }
}

void write_linear(TIFF* tiff, RawFile& raw, const Crop& crop,
                  const ColorMatrix& matrix, const std::string& date_time,
                  const std::array<std::uint32_t, 3>& white) {
  const auto& sizes = raw.imgdata.sizes;
  if (!raw.imgdata.image || !sizes.iwidth || !sizes.iheight) unsupported(raw);
  require_tiff(TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, sizes.iwidth));
  require_tiff(TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, sizes.iheight));
  require_tiff(TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 3));
  require_tiff(TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, 16));
  require_tiff(TIFFSetField(tiff, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT));
  require_tiff(TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, kPhotometricLinearRaw));
  require_tiff(TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG));
  require_tiff(TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE));
  require_tiff(TIFFSetField(tiff, TIFFTAG_ROWSPERSTRIP, 8U));
  common_metadata(tiff, raw, crop, matrix, date_time, true);
  const float black[3] = {0, 0, 0};
  require_tiff(TIFFSetField(tiff, TIFFTAG_BLACKLEVEL, 3, black));
  require_tiff(TIFFSetField(tiff, TIFFTAG_WHITELEVEL, 3, white.data()));

  std::vector<std::uint16_t> row(static_cast<std::size_t>(sizes.iwidth) * 3);
  for (unsigned y = 0; y < sizes.iheight; ++y) {
    check_cancelled();
    const auto* source = raw.imgdata.image + std::size_t(y) * sizes.iwidth;
    for (unsigned x = 0; x < sizes.iwidth; ++x) {
      for (unsigned c = 0; c < 3; ++c) row[std::size_t(x) * 3 + c] = source[x][c];
    }
    if (TIFFWriteScanline(tiff, row.data(), y) < 0) {
      throw std::runtime_error("cannot write LinearRaw DNG samples");
    }
  }
}

std::string conversion_report(const RawFile& raw, const char* layout, const Crop& crop) {
  json::Writer writer;
  writer.begin_object().member("converter", kConverterId).member("layout", layout)
      .member("make", bounded_text(raw.imgdata.idata.make, sizeof(raw.imgdata.idata.make)))
      .member("model", bounded_text(raw.imgdata.idata.model, sizeof(raw.imgdata.idata.model)))
      .member("width", crop.width).member("height", crop.height)
      .member("orientation", orientation_from_flip(raw.imgdata.sizes.flip)).end_object();
  return writer.take() + '\n';
}

std::optional<std::pair<std::uint32_t, std::uint32_t>> jpeg_dimensions(
    std::span<const std::uint8_t> bytes) {
  if (bytes.size() < 4 || bytes[0] != 0xff || bytes[1] != 0xd8) return std::nullopt;
  std::size_t at = 2;
  while (at + 4 <= bytes.size()) {
    if (bytes[at] != 0xff) return std::nullopt;
    while (at < bytes.size() && bytes[at] == 0xff) ++at;
    if (at >= bytes.size()) return std::nullopt;
    const std::uint8_t marker = bytes[at++];
    if (marker == 0xd8 || marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (marker == 0xd9 || marker == 0xda) return std::nullopt;
    if (at + 2 > bytes.size()) return std::nullopt;
    const std::size_t length = (std::size_t(bytes[at]) << 8U) | bytes[at + 1];
    if (length < 2 || length > bytes.size() - at) return std::nullopt;
    const bool sof = (marker >= 0xc0 && marker <= 0xc3) ||
                     (marker >= 0xc5 && marker <= 0xc7) ||
                     (marker >= 0xc9 && marker <= 0xcb) ||
                     (marker >= 0xcd && marker <= 0xcf);
    if (sof) {
      if (length < 7) return std::nullopt;
      const auto height = (std::uint32_t(bytes[at + 3]) << 8U) | bytes[at + 4];
      const auto width = (std::uint32_t(bytes[at + 5]) << 8U) | bytes[at + 6];
      if (width && height) return std::pair{width, height};
      return std::nullopt;
    }
    at += length;
  }
  return std::nullopt;
}

}  // namespace

namespace raw_compat_internal {
bool bayer_pattern(const LibRaw& raw, std::array<std::uint8_t, 4>* output) {
  return bayer_pattern_impl(raw, output);
}
}  // namespace raw_compat_internal

const char* raw_converter_id() noexcept { return kConverterId; }

std::string raw_convert_dng(const std::filesystem::path& raw_path,
                            const std::filesystem::path& dng_path) {
  if (same_path(raw_path, dng_path)) throw std::invalid_argument("RAW and DNG paths must differ");
  auto raw = opened_raw(raw_path);
  check_raw(raw->unpack(), *raw, "LibRaw unpack");
  const auto matrix = color_matrix(*raw);
  auto crop = default_crop(*raw);
  const bool cfa = raw_compat_internal::bayer_pattern(*raw) && raw->imgdata.rawdata.raw_image;
  std::array<std::uint32_t, 3> linear_white{};
  if (!cfa) {
    const auto& color = raw->imgdata.color;
    for (unsigned c = 0; c < 3; ++c) {
      const std::uint64_t level = color.linear_max[c] ? color.linear_max[c] : color.maximum;
      const std::uint64_t subtraction = color.black + color.cblack[c];
      if (!(level > subtraction)) unsupported(*raw);
      linear_white[c] = static_cast<std::uint32_t>(level - subtraction);
    }
    check_raw(raw->dcraw_process(), *raw, "LibRaw LinearRaw processing");
    const auto& sizes = raw->imgdata.sizes;
    // LinearRaw pixels start at LibRaw's visible origin, unlike the CFA
    // buffer, which still includes the whole sensor.
    if (crop.left < sizes.left_margin || crop.top < sizes.top_margin) unsupported(*raw);
    crop.left -= sizes.left_margin;
    crop.top -= sizes.top_margin;
    if (static_cast<std::uint64_t>(crop.left) + crop.width > sizes.iwidth ||
        static_cast<std::uint64_t>(crop.top) + crop.height > sizes.iheight) unsupported(*raw);
  }
  check_cancelled();

  AtomicOutput output(dng_path);
  const int descriptor = output.descriptor();
  TiffHandle tiff(TIFFFdOpen(descriptor, output.temporary_path().c_str(), "wl"));
  if (!tiff) throw std::runtime_error("cannot open DNG output");
  static_cast<void>(output.take_descriptor());  // TIFFClose owns it from here.
  const auto date_time = capture_time(*raw);
  if (cfa) write_cfa(tiff.get(), *raw, crop, matrix, date_time);
  else write_linear(tiff.get(), *raw, crop, matrix, date_time, linear_white);
  require_tiff(TIFFWriteDirectory(tiff.get()));
  write_exif(tiff.get(), *raw, date_time);
  require_tiff(TIFFWriteDirectory(tiff.get()));
  require_tiff(TIFFFlush(tiff.get()));
  check_cancelled();
  const int tiff_descriptor = TIFFFileno(tiff.get());
  TIFFCleanup(tiff.release());
  if (::fsync(tiff_descriptor) != 0) {
    const int error = errno;
    ::close(tiff_descriptor);
    throw std::system_error(error, std::generic_category(), "cannot flush DNG output");
  }
  if (::close(tiff_descriptor) != 0) {
    throw std::system_error(errno, std::generic_category(), "cannot close DNG output");
  }
  output.publish();
  return conversion_report(*raw, cfa ? "cfa" : "linear", crop);
}

std::string raw_extract_preview(const std::filesystem::path& raw_path,
                                const std::filesystem::path& jpeg_path) {
  if (same_path(raw_path, jpeg_path)) throw std::invalid_argument("RAW and preview paths must differ");
  auto raw = opened_raw(raw_path);
  struct Candidate {
    int index{};
    std::uint32_t width{}, height{}, bytes{};
    std::uint64_t area() const { return std::uint64_t(width) * height; }
  };
  Candidate best;
  bool found = false;
  const auto& list = raw->imgdata.thumbs_list;
  for (int index = 0; index < list.thumbcount && index < LIBRAW_THUMBNAIL_MAXCOUNT; ++index) {
    check_cancelled();
    const auto& item = list.thumblist[index];
    if (item.tformat != LIBRAW_INTERNAL_THUMBNAIL_JPEG) continue;
    const int code = raw->unpack_thumb_ex(index);
    if (code == LIBRAW_NO_THUMBNAIL || code == LIBRAW_UNSUPPORTED_THUMBNAIL) continue;
    check_raw(code, *raw, "LibRaw preview unpack");
    const auto& thumb = raw->imgdata.thumbnail;
    if (thumb.tformat != LIBRAW_THUMBNAIL_JPEG || !thumb.thumb || thumb.tlength < 4) continue;
    const auto* bytes = reinterpret_cast<const std::uint8_t*>(thumb.thumb);
    auto dimensions = jpeg_dimensions({bytes, thumb.tlength});
    const std::uint32_t width = dimensions ? dimensions->first : item.twidth;
    const std::uint32_t height = dimensions ? dimensions->second : item.theight;
    if (!width || !height) continue;
    Candidate candidate{index, width, height, thumb.tlength};
    if (!found || candidate.area() > best.area() ||
        (candidate.area() == best.area() && candidate.bytes > best.bytes)) {
      best = candidate;
      found = true;
    }
  }
  if (!found) throw RawNoPreview();
  check_raw(raw->unpack_thumb_ex(best.index), *raw, "LibRaw preview unpack");
  const auto& thumb = raw->imgdata.thumbnail;
  if (thumb.tformat != LIBRAW_THUMBNAIL_JPEG || !thumb.thumb || thumb.tlength < 4) {
    throw RawNoPreview();
  }
  const auto* bytes = reinterpret_cast<const std::uint8_t*>(thumb.thumb);
  if (bytes[0] != 0xff || bytes[1] != 0xd8) throw RawNoPreview();
  check_cancelled();
  AtomicOutput output(jpeg_path);
  write_all(output.descriptor(), bytes, thumb.tlength);
  output.publish();

  const auto& item = raw->imgdata.thumbs_list.thumblist[best.index];
  const auto orientation = orientation_from_flip(item.tflip <= 7 ? item.tflip : raw->imgdata.sizes.flip);
  json::Writer writer;
  writer.begin_object().member("width", best.width).member("height", best.height)
      .member("orientation", orientation).end_object();
  return writer.take() + '\n';
}

}  // namespace hyperdr

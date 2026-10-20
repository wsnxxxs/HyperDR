#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/icc_profiles.hpp"

#include <jpeglib.h>
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include <lcms2.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <csetjmp>
#include <cstdlib>
#include <cstdio>
#include <unistd.h>
#include <cstring>
#include <filesystem>
#include <functional>
#include <span>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {
void (*jpeg_progress_observer)(bool) = nullptr;
void check_jpeg_dimensions(std::uint32_t width, std::uint32_t height) {
  if (width > 65500 || height > 65500)
    throw ExportDimensionLimit(width, height);
}

struct JpegError {
  jpeg_error_mgr base{};
  std::jmp_buf jump{};
  char message[JMSG_LENGTH_MAX]{};
};

void jpeg_fail(j_common_ptr info) {
  auto* error = reinterpret_cast<JpegError*>(info->err);
  (*info->err->format_message)(info, error->message);
  std::longjmp(error->jump, 1);
}

// Compressed bytes go straight into a vector the caller owns. libjpeg-turbo's
// jpeg_mem_dest reallocates privately and publishes the buffer only when the
// image finishes, so a cancelled or failed compression cannot free it safely.
struct VectorDestination {
  jpeg_destination_mgr pub{};
  std::vector<std::uint8_t> bytes;
};
void vector_init(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  dest->bytes.resize(64 * 1024);
  dest->pub.next_output_byte = dest->bytes.data();
  dest->pub.free_in_buffer = dest->bytes.size();
}
boolean vector_grow(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  const auto used = dest->bytes.size();
  dest->bytes.resize(used * 2);
  dest->pub.next_output_byte = dest->bytes.data() + used;
  dest->pub.free_in_buffer = dest->bytes.size() - used;
  return TRUE;
}
void vector_term(j_compress_ptr info) {
  auto* dest = reinterpret_cast<VectorDestination*>(info->dest);
  dest->bytes.resize(dest->bytes.size() - dest->pub.free_in_buffer);
}

std::vector<std::uint8_t> compress_jpeg(const std::uint8_t* pixels, std::uint32_t width,
                                        std::uint32_t height, int components,
                                        J_COLOR_SPACE color_space, int quality,
                                        const std::vector<std::uint8_t>* exif_tiff = nullptr,
                                        const std::vector<std::uint8_t>* icc = nullptr,
                                        bool full_chroma = false,
                                        const std::function<void(unsigned,std::span<std::uint8_t>)>& read_row = {},
                                        FILE* output = nullptr) {
  if ((!pixels && !read_row) || width == 0 || height == 0) {
    throw std::invalid_argument("cannot encode an empty JPEG image");
  }

  std::vector<std::uint8_t> icc_marker, exif_marker;
  if (icc && !icc->empty()) {
    icc_marker = {'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    icc_marker.insert(icc_marker.end(), icc->begin(), icc->end());
    if (icc_marker.size() > 65533) throw std::runtime_error("ICC data is too large for JPEG APP2");
  }
  if (exif_tiff && !exif_tiff->empty()) {
    exif_marker = {'E','x','i','f',0,0};
    exif_marker.insert(exif_marker.end(), exif_tiff->begin(), exif_tiff->end());
    if (exif_marker.size() > 65533) throw std::runtime_error("Exif data is too large for JPEG APP1");
  }
  struct State {
    jpeg_compress_struct info{};
    JpegError error{};
    VectorDestination destination;
    std::vector<std::uint8_t> row;
  };
  auto state = std::make_unique<State>();
  auto& info = state->info;
  auto& error = state->error;
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_compress(&info);
    throw std::runtime_error(std::string("JPEG encode: ") + error.message);
  }

  jpeg_create_compress(&info);
  state->destination.pub.init_destination = vector_init;
  state->destination.pub.empty_output_buffer = vector_grow;
  state->destination.pub.term_destination = vector_term;
  if (output) jpeg_stdio_dest(&info, output);
  else info.dest = &state->destination.pub;
  info.image_width = width;
  info.image_height = height;
  info.input_components = components;
  info.in_color_space = color_space;
  jpeg_set_defaults(&info);
  if (!exif_tiff && !icc) info.write_JFIF_header = FALSE;
  jpeg_set_quality(&info, std::clamp(quality, 0, 100), TRUE);
  if (full_chroma) {
    for (int component = 0; component < info.num_components; ++component) {
      info.comp_info[component].h_samp_factor = 1;
      info.comp_info[component].v_samp_factor = 1;
    }
  }
  // Streaming avoids libjpeg's whole-frame coefficient store. Huffman tables
  // change, but DCT/quantization and decoded samples remain identical.
  info.optimize_coding = output ? FALSE : TRUE;
  struct Progress {
    jpeg_progress_mgr pub{};
    bool finishing = false;
  } progress;
  progress.pub.progress_monitor = [](j_common_ptr common) {
    const auto* self = reinterpret_cast<const Progress*>(common->progress);
    if (jpeg_progress_observer) jpeg_progress_observer(self->finishing);
    check_cancelled();
  };
  info.progress = &progress.pub;
  try {
  jpeg_start_compress(&info, TRUE);

  if (!icc_marker.empty()) jpeg_write_marker(&info, JPEG_APP0 + 2, icc_marker.data(), icc_marker.size());
  if (!exif_marker.empty()) jpeg_write_marker(&info, JPEG_APP0 + 1, exif_marker.data(), exif_marker.size());

  const std::size_t stride = static_cast<std::size_t>(width) * components;
  if (read_row) state->row.resize(stride);
  while (info.next_scanline < info.image_height) {
    check_cancelled();
    auto* row = state->row.data();
    if (read_row) read_row(info.next_scanline,state->row);
    else row = const_cast<JSAMPLE*>(pixels + static_cast<std::size_t>(info.next_scanline) * stride);
    jpeg_write_scanlines(&info, &row, 1);
  }
  // With optimize_coding the entropy coding and most of the output happen
  // here, so a cancellation lands mid-output as often as not.
  progress.finishing = true;
  jpeg_finish_compress(&info);
  jpeg_destroy_compress(&info);
  return std::move(state->destination.bytes);
  } catch (...) {
    jpeg_destroy_compress(&info); throw;
  }
}

std::vector<std::uint8_t> make_base_jpeg(const FloatImage& image,
                                         const PhotoMetadata& metadata, int quality,
                                         bool clamp_srgb) {
  image.require_consistent("gain-map JPEG base");
  check_jpeg_dimensions(image.width, image.height);
  if (image.channels != 3) throw std::invalid_argument("gain-map JPEG base must be RGB");
  const auto row = [&](std::uint32_t y, std::span<std::uint8_t> rgb) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto base = (static_cast<std::size_t>(y) * image.width + x) * 3;
      const auto fitted = clamp_srgb
                              ? compress_linear_p3_to_srgb(
                                    image.pixels[base], image.pixels[base + 1],
                                    image.pixels[base + 2])
                              : std::array<float, 3>{image.pixels[base],
                                                     image.pixels[base + 1],
                                                     image.pixels[base + 2]};
      for (unsigned c = 0; c < 3; ++c) {
        rgb[x * 3 + c] = static_cast<std::uint8_t>(quantize_dithered(
            srgb_oetf(fitted[c]), 255, x, y, c));
      }
    }
  };
  const auto exif = make_minimal_exif(metadata);
  // Gamut compression retains P3 coordinates even when clamp_srgb is enabled.
  // Both modes therefore store Display P3 primaries with the sRGB transfer.
  const auto icc = codec::display_p3_profile();
  return compress_jpeg(nullptr, image.width, image.height, 3, JCS_RGB, quality, &exif,
                       &icc, false, row);
}

std::vector<std::uint8_t> make_gain_jpeg(const FloatImage& image, int quality) {
  if (image.channels != 1 && image.channels != 3) {
    throw std::invalid_argument("gain-map JPEG recovery map must have one or three channels");
  }
  check_jpeg_dimensions(image.width, image.height);
  std::vector<std::uint8_t> pixels(image.pixels.size());
  const std::size_t stride = static_cast<std::size_t>(image.width) * image.channels;
  for (std::uint32_t y = 0; y < image.height; ++y) {
    check_cancelled();
    for (std::size_t i = y * stride; i < (y + 1) * stride; ++i) {
    pixels[i] = static_cast<std::uint8_t>(
        std::lround(std::clamp(image.pixels[i], 0.0F, 1.0F) * 255.0F));
  }
  }
  return compress_jpeg(pixels.data(), image.width, image.height, image.channels,
      image.channels == 1 ? JCS_GRAYSCALE : JCS_RGB, quality, nullptr, nullptr, true);
}

}  // namespace

std::vector<std::uint8_t> encode_sdr_jpeg(const FloatImage& image,
    const PhotoMetadata& metadata, int quality, ColorGamut gamut) {
  image.require_consistent("SDR JPEG");
  check_jpeg_dimensions(image.width, image.height);
  if (image.channels != 3) throw std::invalid_argument("SDR JPEG requires RGB");
  if (gamut != ColorGamut::kSrgb && gamut != ColorGamut::kDisplayP3)
    throw std::invalid_argument("SDR JPEG supports sRGB or Display P3");
  std::vector<std::uint8_t> rgb(image.pixels.size());
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    for (std::uint32_t x=0;x<image.width;++x) {
      const auto i=(static_cast<std::size_t>(y)*image.width+x)*3;
      auto color=fit_linear_p3_gamut(image.pixels[i],image.pixels[i+1],image.pixels[i+2],1.0F,
                                    gamut == ColorGamut::kSrgb);
      if (gamut == ColorGamut::kSrgb) color=linear_p3_to_rec709(color[0],color[1],color[2]);
      for (unsigned c=0;c<3;++c) rgb[i+c]=static_cast<std::uint8_t>(quantize_dithered(srgb_oetf(color[c]),255,x,y,c));
    }
  });
  const auto icc = gamut == ColorGamut::kSrgb ? codec::srgb_profile() : codec::display_p3_profile();
  const auto exif=make_minimal_exif(metadata);
  return compress_jpeg(rgb.data(),image.width,image.height,3,JCS_RGB,quality,&exif,&icc);
}

namespace {
struct FileCloser { void operator()(FILE* f) const { if(f) std::fclose(f); } };
using FileHandle = std::unique_ptr<FILE,FileCloser>;
void finish_file(FileHandle& file) {
  if (std::fflush(file.get()) != 0) throw std::runtime_error("streaming JPEG flush failed");
  if (std::fclose(file.release()) != 0) throw std::runtime_error("streaming JPEG close failed");
}

FileHandle output_file(const std::filesystem::path& path) {
  FileHandle f(std::fopen(path.c_str(),"wb"));
  if(!f) throw std::runtime_error("cannot open streaming JPEG output");
  return f;
}
FileHandle temporary_jpeg(const std::filesystem::path& output) {
  // Use the writable export directory, including in an iOS sandbox; tmpfile()
  // may choose a system directory outside the application's container.
  auto name=(output.parent_path()/".hyperdr-jpeg-XXXXXX").native();
  const int fd=::mkstemp(name.data());
  if(fd<0)throw std::runtime_error("cannot stage streaming JPEG component");
  ::unlink(name.c_str());
  FileHandle file(::fdopen(fd,"w+b"));
  if(!file) { ::close(fd);throw std::runtime_error("cannot open streaming JPEG component"); }
  return file;
}
void base_rows_jpeg(const EncodingRows& source, const PhotoMetadata& photo, int quality,
                    ColorGamut gamut, bool ordinary, FILE* out) {
  check_jpeg_dimensions(source.width,source.height);
  std::vector<float> linear(std::size_t(source.width)*3);
  const auto row = [&](unsigned y,std::span<std::uint8_t> encoded) {
    source.read(y,linear);
    for(unsigned x=0;x<source.width;++x) {
      const auto i=std::size_t(x)*3;
      auto rgb=std::array<float,3>{linear[i],linear[i+1],linear[i+2]};
      if(ordinary) {
        // Match package_image's fit_sdr_to_srgb, then the SDR writer's fit.
        if(gamut==ColorGamut::kSrgb) rgb=compress_linear_p3_to_srgb(rgb[0],rgb[1],rgb[2]);
        rgb=fit_linear_p3_gamut(rgb[0],rgb[1],rgb[2],1,gamut==ColorGamut::kSrgb);
        if(gamut==ColorGamut::kSrgb) rgb=linear_p3_to_rec709(rgb[0],rgb[1],rgb[2]);
      }
      for(unsigned c=0;c<3;++c) encoded[i+c]=std::uint8_t(quantize_dithered(srgb_oetf(rgb[c]),255,x,y,c));
    }
  };
  const auto icc=gamut==ColorGamut::kSrgb?codec::srgb_profile():codec::display_p3_profile();
  const auto exif=make_minimal_exif(photo);
  (void)compress_jpeg(nullptr,source.width,source.height,3,JCS_RGB,quality,&exif,&icc,false,row,out);
}
}
void write_sdr_jpeg_rows(const EncodingRows& source,const PhotoMetadata& photo,int quality,
                         ColorGamut gamut,const std::filesystem::path& path) {
  auto output=output_file(path);base_rows_jpeg(source,photo,quality,gamut,true,output.get());
  finish_file(output);
}
void write_gain_map_jpeg_rows(const EncodingRows& base,const EncodingRows& gain,
    const GainMapMetadata& metadata,const PhotoMetadata& photo,int quality,bool frame,
    const std::filesystem::path& path) {
  auto primary=temporary_jpeg(path), auxiliary=temporary_jpeg(path);
  if(!primary||!auxiliary) throw std::runtime_error("cannot stage streaming JPEG components");
  base_rows_jpeg(base,photo,quality,ColorGamut::kDisplayP3,false,primary.get());
  std::vector<float> linear(std::size_t(gain.width)*gain.channels);
  const auto row=[&](unsigned y,std::span<std::uint8_t> encoded) {
    gain.read(y,linear);
    for(std::size_t i=0;i<linear.size();++i) encoded[i]=std::uint8_t(std::lround(std::clamp(linear[i],0.f,1.f)*255));
  };
  (void)compress_jpeg(nullptr,gain.width,gain.height,gain.channels,
      gain.channels==1?JCS_GRAYSCALE:JCS_RGB,frame?100:std::max(90,quality),nullptr,nullptr,true,row,auxiliary.get());
  auto output=output_file(path);
  write_gain_map_jpeg(primary.get(),auxiliary.get(),output.get(),metadata);
  finish_file(primary);finish_file(auxiliary);finish_file(output);
}

namespace {
std::array<unsigned, 3> decode_jpeg_for_verification(const std::uint8_t* bytes, std::size_t size) {
  struct State { jpeg_decompress_struct info{}; JpegError error{}; };
  auto state = std::make_unique<State>();
  auto& info = state->info;
  auto& error = state->error;
  info.err = jpeg_std_error(&error.base); error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_decompress(&info);
    throw std::runtime_error(std::string("JPEG verification: ") + error.message);
  }
  jpeg_create_decompress(&info);
  try {
    jpeg_mem_src(&info, bytes, static_cast<unsigned long>(size));
    jpeg_read_header(&info, TRUE);
    const std::array<unsigned, 3> result{info.image_width, info.image_height, static_cast<unsigned>(info.num_components)};
    jpeg_start_decompress(&info);
    auto row = (*info.mem->alloc_sarray)(reinterpret_cast<j_common_ptr>(&info), JPOOL_IMAGE,
        info.output_width * info.output_components, 1);
    while (info.output_scanline < info.output_height) {
      check_cancelled();
      jpeg_read_scanlines(&info, row, 1);
    }
    jpeg_finish_decompress(&info);
    const bool warnings = info.err->num_warnings != 0;
    jpeg_destroy_decompress(&info);
    if (warnings) throw std::runtime_error("JPEG verification: corrupt/truncated image data");
    return result;
  } catch (...) { jpeg_destroy_decompress(&info); throw; }
}
}  // namespace
namespace testing {
void set_jpeg_progress_observer(void (*observer)(bool finishing)) {
  jpeg_progress_observer = observer;
}
}  // namespace testing

void verify_sdr_jpeg(std::span<const std::uint8_t> bytes) {
  (void)decode_jpeg_for_verification(bytes.data(), bytes.size());
}

static std::vector<std::uint8_t> encode_gain_map_jpeg_impl(const GainMapResult& images,
    const PhotoMetadata& metadata, int quality, GainMapResult* owned) {
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  images.gain_map.require_consistent("gain-map JPEG recovery map");
  validate_gain_map_metadata(images.metadata);
  const auto channels = gain_map_channel_count(images.metadata);
  images.base_linear.require_consistent("gain-map JPEG base");
  check_jpeg_dimensions(images.base_linear.width, images.base_linear.height);
  check_jpeg_dimensions(images.gain_map.width, images.gain_map.height);
  if (!images.gain_map.width || !images.gain_map.height ||
      images.base_linear.width % images.gain_map.width ||
      images.base_linear.height % images.gain_map.height ||
      images.base_linear.width / images.gain_map.width != images.base_linear.height / images.gain_map.height)
    throw std::invalid_argument("gain-map JPEG requires an integer image scale");
  if (images.gain_map.channels != channels) {
    throw std::invalid_argument("gain-map JPEG recovery pixels and metadata must have matching channels");
  }
  // The gain map relates the two uncompressed renditions; it does not correct
  // the base's compression error. The base is therefore an ordinary 4:2:0 JPEG
  // like an SDR export, and the HDR rendition is as faithful as that base.
  const auto gain_width=images.gain_map.width, gain_height=images.gain_map.height,
             gain_channels=images.gain_map.channels;
  std::vector<std::uint8_t,PlaneAllocator<std::uint8_t>> packed;
  if (owned) {
    packed.resize(images.gain_map.pixels.size());
    const auto stride=static_cast<std::size_t>(gain_width)*gain_channels;
    for(unsigned y=0;y<gain_height;++y) {
      check_cancelled();
      for(std::size_t i=y*stride;i<(y+1)*stride;++i)
        packed[i]=static_cast<std::uint8_t>(std::lround(std::clamp(images.gain_map.pixels[i],0.0F,1.0F)*255));
    }
    owned->gain_map={};
  }
  auto base_bytes = make_base_jpeg(images.base_linear, metadata, quality, images.clamp_srgb);
  // A lower base quality should not also coarsen the gain, so the gain map
  // never drops below 90.
  // With a frame the photo/mat step can ring several codes into the mat at
  // quality 95. Unit DCT quantizers bound this independently of base quality;
  // unframed exports retain their exact previous byte stream.
  const auto gain_quality=images.presentation_frame ? 100 : std::max(90, quality);
  auto gain_bytes = owned
      ? compress_jpeg(packed.data(),gain_width,gain_height,gain_channels,
          gain_channels==1 ? JCS_GRAYSCALE : JCS_RGB,gain_quality,nullptr,nullptr,true)
      : make_gain_jpeg(images.gain_map,gain_quality);

  return assemble_gain_map_jpeg(base_bytes, gain_bytes, images.metadata);
}

std::vector<std::uint8_t> encode_gain_map_jpeg(const GainMapResult& images,
    const PhotoMetadata& metadata,int quality) {
  return encode_gain_map_jpeg_impl(images,metadata,quality,nullptr);
}
std::vector<std::uint8_t> encode_gain_map_jpeg(GainMapResult&& images,
    const PhotoMetadata& metadata,int quality) {
  return encode_gain_map_jpeg_impl(images,metadata,quality,&images);
}

static GainMapJpeg verified_gain_jpeg_metadata(std::span<const std::uint8_t> bytes) {
  const auto parsed = parse_gain_map_jpeg(bytes);
  // HyperDR writes ISO 21496-1 only. A file that also describes its gain map
  // in Ultra HDR XMP (an Android 15 photo, for instance) is valid elsewhere
  // but is not one of this program's exports.
  if (parsed.has_hdrgm)
    throw std::runtime_error("gain-map JPEG also carries Ultra HDR XMP (hdrgm) gain metadata; "
                             "HyperDR exports carry ISO 21496-1 metadata only");
  if (parsed.has_container_directory)
    throw std::runtime_error("gain-map JPEG carries an XMP Container:Directory; "
                             "HyperDR exports locate the gain map through MPF only");
  validate_gain_map_metadata(parsed.metadata, GainMapWriterProfile::iso_generic);
  bool icc = false;
  for (const auto& app : parsed.app_segments[0]) {
    constexpr char signature[] = "ICC_PROFILE";
    if (app.marker == 0xe2 && app.payload.size() > 14 &&
        std::equal(signature, signature + sizeof(signature), app.payload.begin())) icc = true;
  }
  if (!icc) throw std::runtime_error("gain-map JPEG has no primary ICC profile");
  return parsed;
}
void verify_gain_map_jpeg(std::span<const std::uint8_t> bytes) {
  const auto parsed=verified_gain_jpeg_metadata(bytes);
  const auto base = decode_jpeg_for_verification(bytes.data(), parsed.primary_size);
  const auto gain = decode_jpeg_for_verification(bytes.data() + parsed.gain_offset, parsed.gain_size);
  if (base[2] != 3 || gain[2] != gain_map_channel_count(parsed.metadata) ||
      !gain[0] || !gain[1] || base[0] % gain[0] || base[1] % gain[1] ||
      base[0] / gain[0] != base[1] / gain[1])
    throw std::runtime_error("gain-map JPEG raster dimensions/channels do not match metadata");
}


void verify_gain_map_jpeg(const std::filesystem::path& input) {
  verify_gain_map_jpeg(read_binary_file(input));
}

}  // namespace hyperdr

#include "internal/cicp.hpp"
#include "internal/verify_pixels.hpp"
#include "hyperdr/look/grid.hpp"
namespace hyperdr::codec {
namespace {
// Heap state keeps setjmp storage off the C ABI's 512 KB stack. Every libjpeg
// operation installs a live jump target; C++ buffers remain owned by the reader.
class VerificationJpeg {
  struct State {
    jpeg_decompress_struct info{}; JpegError error{}; bool created=false;
    ~State() { if(created)jpeg_destroy_decompress(&info); }
  };
  std::unique_ptr<State> state=std::make_unique<State>();
 public:
  unsigned width=0,height=0,channels=0;
  std::vector<std::uint8_t> pixels;
  VerificationJpeg(std::span<const std::uint8_t> bytes) {
    auto& s=*state;s.info.err=jpeg_std_error(&s.error.base);s.error.base.error_exit=jpeg_fail;
    if(setjmp(s.error.jump)) { if(s.created)jpeg_destroy_decompress(&s.info);s.created=false;
      throw std::runtime_error(std::string("JPEG verification: ")+s.error.message); }
    jpeg_create_decompress(&s.info);s.created=true;
    jpeg_mem_src(&s.info,bytes.data(),bytes.size());
    jpeg_save_markers(&s.info,JPEG_APP0+1,0xffff);
    jpeg_read_header(&s.info,TRUE);
    for(auto* marker=s.info.marker_list;marker;marker=marker->next) {
      if(marker->data_length>=6 && std::memcmp(marker->data,"Exif\0\0",6)==0 &&
         read_exif_orientation(marker->data+6,marker->data_length-6).value_or(1)!=1)
        throw std::runtime_error("bounded export verification requires EXIF Orientation=1");
    }
    // HyperDR writes baseline JPEG. Progressive decoding needs a whole-image
    // coefficient array in libjpeg, so it cannot enter the bounded verifier.
    if(s.info.progressive_mode || s.info.arith_code) {
      jpeg_destroy_decompress(&s.info);s.created=false;
      throw std::runtime_error("bounded JPEG verification requires baseline Huffman JPEG");
    }
    jpeg_start_decompress(&s.info);
    width=s.info.output_width;height=s.info.output_height;channels=s.info.output_components;
    pixels.resize(std::size_t(width)*channels);
  }
  ~VerificationJpeg() = default;
  void read() {
    auto& s=*state;
    if(setjmp(s.error.jump))throw std::runtime_error(std::string("JPEG verification: ")+s.error.message);
    check_cancelled();JSAMPROW row=pixels.data();
    if(jpeg_read_scanlines(&s.info,&row,1)!=1)throw std::runtime_error("JPEG scanline missing");
  }
  void finish() {
    auto& s=*state;
    if(setjmp(s.error.jump))throw std::runtime_error(std::string("JPEG verification: ")+s.error.message);
    jpeg_finish_decompress(&s.info);
    if(s.info.err->num_warnings)throw std::runtime_error("JPEG verification: corrupt/truncated image data");
  }
};
std::vector<std::uint8_t> verificationICC(const std::vector<JpegAppSegment>& apps) {
  std::vector<std::vector<std::uint8_t>> parts;
  for(const auto& app:apps) {
    const auto& b=app.payload;
    if(app.marker!=0xe2||b.size()<14||std::memcmp(b.data(),"ICC_PROFILE\0",12))continue;
    if(!b[12]||!b[13]||b[12]>b[13]||(!parts.empty()&&parts.size()!=b[13]))throw std::runtime_error("invalid JPEG ICC sequence");
    parts.resize(b[13]);
    if(!parts[b[12]-1].empty())throw std::runtime_error("duplicate JPEG ICC sequence");
    parts[b[12]-1].assign(b.begin()+14,b.end());
  }
  std::vector<std::uint8_t> result;
  for(const auto& part:parts) {
    if(part.empty())throw std::runtime_error("incomplete JPEG ICC sequence");
    result.insert(result.end(),part.begin(),part.end());
  }
  return result;
}
}
VerificationResult verify_jpeg_pixels(std::span<const std::uint8_t> bytes,bool hasGain,
                                      std::optional<VerificationFrame> frame) {
  std::optional<GainMapJpeg> parsed;
  // Share every original structural/metadata gate; pixels then traverse only
  // the bounded readers below (never a progressive coefficient buffer).
  if(hasGain) parsed=verified_gain_jpeg_metadata(bytes);
  VerificationJpeg base(hasGain?bytes.first(parsed->primary_size):bytes);
  if(base.channels!=3)throw std::runtime_error("export JPEG base is not RGB");
  SourceColor color(hasGain?ColorGamut::kDisplayP3:ColorGamut::kSrgb);
  if(parsed) { color.icc=verificationICC(parsed->app_segments[0]);color.source="icc"; }
  // SDR JPEG has no pair/frame. Its original decoder checks all native rows.
  if(!hasGain) {
    VerificationPixels check(base.width,base.height,frame);
    std::vector<float> row(std::size_t(base.width)*3);
    for(unsigned y=0;y<base.height;++y) { base.read();for(std::size_t i=0;i<row.size();++i)row[i]=base.pixels[i]/255.f;check.row(0,y,row); }
    base.finish();return check.result;
  }
  const RgbRowTransform transform(color,8,false,false);
  VerificationJpeg gain(bytes.subspan(parsed->gain_offset,parsed->gain_size));
  const unsigned channels=gain_map_channel_count(parsed->metadata);
  if(gain.channels!=channels || !gain.width || !gain.height ||
     base.width%gain.width || base.height%gain.height || base.width/gain.width!=base.height/gain.height)
    throw std::runtime_error("gain-map JPEG raster dimensions/channels do not match metadata");
  VerificationPixels check(base.width,base.height,frame,parsed->metadata);
  BilinearGridSampler sampler(gain.width,gain.height,base.width,base.height);
  std::vector<float> gainRows[2];
  for(auto& row:gainRows)row.resize(std::size_t(gain.width)*channels);
  std::vector<float> linear(std::size_t(base.width)*3),expanded(std::size_t(base.width)*channels);
  unsigned nextGain=0;
  for(unsigned y=0;y<base.height;++y) {
    base.read();transform.convert(base.pixels.data(),linear.data(),base.width);
    const auto cy=sampler.coordinates(0,y);
    while(nextGain<=cy.y1) {
      gain.read();auto& row=gainRows[nextGain%2];
      for(std::size_t i=0;i<row.size();++i) {
        row[i]=gain.pixels[i]/255.f;
        const auto c=gain_map_channel(parsed->metadata,i%channels);
        const float g=std::lerp(rational_value(c.gain_min),rational_value(c.gain_max),std::pow(row[i],1.f/rational_value(c.gamma)));
        check.result.gainMinimum=std::min(check.result.gainMinimum,g);check.result.gainMaximum=std::max(check.result.gainMaximum,g);
      }
      ++nextGain;
    }
    for(unsigned x=0;x<base.width;++x) {
      const auto p=sampler.coordinates(x,y);
      for(unsigned c=0;c<channels;++c) {
        const auto& a=gainRows[p.y0%2];const auto& b=gainRows[p.y1%2];
        expanded[x*channels+c]=std::lerp(std::lerp(a[p.x0*channels+c],a[p.x1*channels+c],p.tx),
            std::lerp(b[p.x0*channels+c],b[p.x1*channels+c],p.tx),p.ty);
      }
    }
    check.row(0,y,linear,expanded);
  }
  base.finish();gain.finish();return check.result;
}
} // namespace hyperdr::codec

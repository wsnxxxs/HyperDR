// ISO and XMP JPEG inputs share reconstruction and colour conversion.
#include "internal/decode_bytes.hpp"
#include "internal/gain_map_jpeg.hpp"
#include "internal/cicp.hpp"
#include "internal/metadata.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/image/orientation.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include <cstring>
#include "hyperdr/foundation/file_io.hpp"

namespace hyperdr::codec {
bool is_ultrahdr_bytes(const std::vector<std::uint8_t>& bytes) {
  try {
    if(has_gain_map_jpeg_signature(bytes))return true;
    const auto jpeg=inspect_gain_map_jpeg(bytes);
    return jpeg.primary_iso_count || jpeg.gain_iso_count || jpeg.has_hdrgm;
  } catch(const Cancelled&) { throw; }
    catch(const std::exception&) { return false; }
}
DecodedImage decode_ultrahdr_bytes(const std::vector<std::uint8_t>& bytes,ColorGamut gamut) {
  const auto jpeg=inspect_gain_map_jpeg(bytes);
  if(jpeg.primary_iso_count>1 || jpeg.gain_iso_count>1)
    throw std::runtime_error("duplicate ISO gain-map metadata");
  if(jpeg.primary_iso_count || jpeg.gain_iso_count) return decode_iso_gain_map_jpeg_bytes(bytes,gamut);
  return decode_iso_gain_map_jpeg_bytes(bytes,gamut);
}
namespace {
std::vector<std::uint8_t> icc_profile(const std::vector<JpegAppSegment>& apps) {
  std::vector<std::vector<std::uint8_t>> parts;
  unsigned count = 0;
  for (const auto& app : apps) {
    const auto& b = app.payload;
    if (app.marker != 0xe2 || b.size() < 14 || std::memcmp(b.data(), "ICC_PROFILE\0", 12)) continue;
    if (!b[12] || !b[13] || b[12] > b[13] || (count && count != b[13]))
      throw std::runtime_error("invalid JPEG ICC sequence");
    count = b[13]; parts.resize(count);
    if (!parts[b[12]-1].empty()) throw std::runtime_error("duplicate JPEG ICC sequence");
    parts[b[12]-1].assign(b.begin()+14,b.end());
  }
  std::vector<std::uint8_t> bytes;
  for (const auto& part : parts) {
    if (part.empty()) throw std::runtime_error("incomplete JPEG ICC sequence");
    bytes.insert(bytes.end(),part.begin(),part.end());
  }
  return bytes;
}
void transform(FloatImage& image, cmsHTRANSFORM conversion) {
  parallel_for_rows(image.height,[&](std::uint32_t y) {
    auto* row = image.pixels.data()+static_cast<std::size_t>(y)*image.width*3;
    cmsDoTransform(conversion,row,row,image.width);
  });
}
}
DecodedImage decode_iso_gain_map_jpeg_bytes(const std::vector<std::uint8_t>& bytes,
                                           ColorGamut default_gamut) {
  check_cancelled();
  auto jpeg = inspect_gain_map_jpeg(bytes);
  GainMapRead input;
  if (jpeg.primary_iso_count || jpeg.gain_iso_count) {
    jpeg = parse_gain_map_jpeg_input(bytes);
    input.metadata = jpeg.metadata;
    input.pixels = decode_jpeg_gain_bytes({bytes.begin()+jpeg.gain_offset,
        bytes.begin()+jpeg.gain_offset+jpeg.gain_size},gain_map_channel_count(jpeg.metadata));
  } else {
    input = read_gain_map_jpeg_imageio(bytes);
    jpeg.metadata = input.metadata;
  }
  auto primary = decode_jpeg_primary_bytes(bytes, default_gamut);
  if (primary.decode.resolution_reduced) throw std::runtime_error("gain-map primary exceeds decode budget");
  const auto channels = gain_map_channel_count(jpeg.metadata);
  auto gain=std::move(input.pixels);
  unsigned orientation = 1;
  for (const auto& app : jpeg.app_segments[0]) {
    if (app.marker == 0xe1 && app.payload.size() > 6 &&
        !std::memcmp(app.payload.data(),"Exif\0\0",6)) {
      const auto exif = read_exif(app.payload.data()+6,app.payload.size()-6);
      orientation = exif.orientation.value_or(1); break;
    }
  }
  gain = apply_exif_orientation(std::move(gain),orientation);
  auto base = primary.linear_p3;
  ProfileHandle native;
  auto icc = icc_profile(jpeg.app_segments[jpeg.metadata.use_base_color_space ? 0 : 1]);
  // An auxiliary without an ICC inherits the primary colour space.
  if(icc.empty() && !jpeg.metadata.use_base_color_space)icc=icc_profile(jpeg.app_segments[0]);
  if (!icc.empty()) native.reset(cmsOpenProfileFromMem(icc.data(),icc.size()));
  else {
    // A missing ICC uses the same explicit default as the primary decoder.
    if (default_gamut == ColorGamut::kSrgb) native.reset(cmsCreate_sRGBProfile());
    else {
      const cmsCIExyY white{.3127,.3290,1};
      const cmsCIExyYTRIPLE gamut = default_gamut == ColorGamut::kDisplayP3
          ? cmsCIExyYTRIPLE{{.680,.320,1},{.265,.690,1},{.150,.060,1}}
          : cmsCIExyYTRIPLE{{.708,.292,1},{.170,.797,1},{.131,.046,1}};
      cmsToneCurve* curve = cmsBuildGamma(nullptr,1);
      cmsToneCurve* curves[]{curve,curve,curve};
      native.reset(cmsCreateRGBProfile(&white,&gamut,curves));
      cmsFreeToneCurve(curve);
    }
  }
  if (!native) throw std::runtime_error("invalid gain-map primary ICC");
  // Strip only the transfer curves from a private copy. Chromatic adaptation
  // and primaries stay in lcms, including arbitrary matrix RGB ICC profiles.
  cmsToneCurve* linear = cmsBuildGamma(nullptr,1);
  if (!linear) throw std::runtime_error("cannot create linear ICC curve");
  const bool linearized = cmsWriteTag(native.get(),cmsSigRedTRCTag,linear) &&
      cmsWriteTag(native.get(),cmsSigGreenTRCTag,linear) &&
      cmsWriteTag(native.get(),cmsSigBlueTRCTag,linear);
  cmsFreeToneCurve(linear);
  if (!linearized || !cmsIsMatrixShaper(native.get()))
    throw std::runtime_error("gain-map primary requires a matrix RGB ICC profile");
  auto p3 = linear_display_p3_profile();
  TransformHandle to_native(cmsCreateTransform(p3.get(),TYPE_RGB_FLT,native.get(),TYPE_RGB_FLT,
      INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOCACHE|cmsFLAGS_NOOPTIMIZE));
  TransformHandle to_p3(cmsCreateTransform(native.get(),TYPE_RGB_FLT,p3.get(),TYPE_RGB_FLT,
      INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOCACHE|cmsFLAGS_NOOPTIMIZE));
  if (!to_native || !to_p3) throw std::runtime_error("cannot transform gain-map colour space");
  transform(base,to_native.get());
  const float hdr_headroom = std::max(rational_value(jpeg.metadata.base_headroom),
                                    rational_value(jpeg.metadata.alternate_headroom));
  auto hdr = reconstruct_gain_map(base,gain,jpeg.metadata,hdr_headroom);
  transform(hdr,to_p3.get());
  DecodedImage result = std::move(primary);
  result.authored_sdr = std::move(result.linear_p3);
  result.linear_p3 = std::move(hdr);
  result.domain = InputDomain::kDualRendition;
  result.source_color = {"Ultra HDR",result.source_color.primaries,
                         "Gain-map HDR reconstruction","ultrahdr"};
  result.hdr_headroom = measured_alternate_headroom(result.linear_p3);
  result.gain_map.channels = channels;
  result.gain_map.base_headroom = std::exp2(rational_value(jpeg.metadata.base_headroom));
  result.gain_map.alternate_headroom = std::exp2(rational_value(jpeg.metadata.alternate_headroom));
  for (unsigned c=0;c<3;++c) {
    const auto channel = gain_map_channel(jpeg.metadata,channels==1?0:c);
    result.gain_map.base_offset[c] = rational_value(channel.base_offset);
    result.gain_map.alternate_offset[c] = rational_value(channel.alternate_offset);
  }
  return result;
}
} // namespace hyperdr::codec

namespace hyperdr {
bool is_ultrahdr_jpeg_file(const std::filesystem::path& path) {
  try { return codec::is_ultrahdr_bytes(read_binary_file(path)); }
  catch(const std::exception&) { return false; }
}
DecodedImage decode_ultrahdr(const std::filesystem::path& path) {
  return codec::decode_ultrahdr_bytes(read_binary_file(path),ColorGamut::kSrgb);
}
}

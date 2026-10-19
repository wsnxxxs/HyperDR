#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"

#include <libheif/heif.h>
#include <libheif/heif_tiling.h>
#include "internal/icc_profiles.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>

namespace hyperdr {
namespace {

void check_heif(heif_error error, const char* operation) {
  if (error.code != heif_error_Ok) throw std::runtime_error(std::string(operation) + ": " + (error.message ? error.message : "unknown libheif error"));
}

struct ImageDeleter { void operator()(heif_image* p) const { if(p)heif_image_release(p); } };
struct HandleDeleter { void operator()(heif_image_handle* p) const { if(p)heif_image_handle_release(p); } };
struct ContextDeleter { void operator()(heif_context* p) const { if(p)heif_context_free(p); } };
struct DecodingOptionsDeleter { void operator()(heif_decoding_options* p) const { if(p)heif_decoding_options_free(p); } };
void validate_base_profile(const heif_image_handle* handle) {
  heif_color_profile_nclx* nclx = nullptr;
  const auto error = heif_image_handle_get_nclx_color_profile(handle, &nclx);
  const bool has_icc = heif_image_handle_get_raw_color_profile_size(handle) > 0;
  const bool has_nclx = nclx != nullptr;
  const bool valid_nclx = error.code == heif_error_Ok && nclx &&
                          (nclx->color_primaries == heif_color_primaries_SMPTE_EG_432_1 ||
                           nclx->color_primaries == heif_color_primaries_ITU_R_BT_709_5 ||
                           nclx->color_primaries == heif_color_primaries_unspecified) &&
                          (nclx->transfer_characteristics ==
                               heif_transfer_characteristic_IEC_61966_2_1 ||
                           nclx->transfer_characteristics ==
                               heif_transfer_characteristic_ITU_R_BT_709_5 ||
                           nclx->transfer_characteristics ==
                               heif_transfer_characteristic_unspecified) &&
                          (nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 ||
                           nclx->matrix_coefficients == heif_matrix_coefficients_unspecified) &&
                          nclx->full_range_flag == 1;
  if (nclx) heif_nclx_color_profile_free(nclx);
  // Apple files in the wild use either an ICC-only Display-P3 profile or an
  // nclx-only BT.709/sRGB profile. Both are valid SDR bases for the verified
  // single-channel forward subset; HyperDR-produced files still carry both.
  // A nclx-only Apple base may be exposed by libheif as an unavailable
  // profile (the property is attached through ipma). The HEIF structural
  // inspection has already validated the item graph, so absence of an ICC is
  // not grounds to reject that legal source. When an ICC is present, however,
  // an explicitly present nclx must still be internally consistent.
  if (has_icc && has_nclx && !valid_nclx) {
    throw std::runtime_error("SDR base lacks a usable ICC or nclx SDR profile");
  }
}

void validate_gain_profile(const heif_image_handle* handle) {
  heif_color_profile_nclx* nclx = nullptr;
  const auto error = heif_image_handle_get_nclx_color_profile(handle, &nclx);
  // Apple's gain-map item is often deliberately unprofiled; the metadata
  // carries the ISO interpretation and the image is an 8-bit luma plane.
  // HyperDR-produced files do carry the strict unspecified/BT.709 nclx below,
  // so an explicitly present profile is still checked rather than ignored.
  const bool valid = error.code != heif_error_Ok || nclx == nullptr ||
                     (nclx->color_primaries == heif_color_primaries_unspecified &&
                      nclx->transfer_characteristics ==
                          heif_transfer_characteristic_unspecified &&
                      nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 &&
                      nclx->full_range_flag == 1);
  if (nclx) heif_nclx_color_profile_free(nclx);
  if (!valid) throw std::runtime_error("Gain Map lacks required nclx 2/2/1/full");
}

// A bounded batch of YUV tiles is converted in parallel, then fed in row-major
// order to one VT session. Conversion concurrency never changes the bitstream.
template<class Convert>
codec::hevc::EncodedSequence encode_picture(const codec::hevc::TileGrid& grid,
    const codec::hevc::EncodeParams& params,const Convert& convert) {
  using namespace codec::hevc;
  const unsigned automatic=std::clamp(std::thread::hardware_concurrency()/4U,1U,4U);
  const auto requested=current_execution_config.heic_tile_workers;
  const std::size_t workers=std::min<std::size_t>(requested?requested:automatic,grid.count());
  std::vector<YuvTile> batch(workers);
  return encode(grid.count(),[&](std::size_t index,YuvTile& tile){
    if(index%workers==0){
      const auto count=std::min(workers,grid.count()-index);
      std::exception_ptr failure;std::mutex mutex;
      const auto run=[&,token=current_cancel_token,config=current_execution_config](std::size_t i){
        CancelScope cancel(token);ExecutionScope execution(config);
        try{check_cancelled();batch[i]=make_tile(params.main10?10:8);convert(index+i,batch[i]);}
        catch(...){std::lock_guard lock(mutex);if(!failure)failure=std::current_exception();}
      };
      {std::vector<std::jthread> threads;for(std::size_t i=1;i<count;++i)threads.emplace_back(run,i);run(0);}
      if(failure)std::rethrow_exception(failure);
    }
    tile=std::move(batch[index%workers]);
  },params);
}
codec::hevc::EncodedSequence encode_base(const FloatImage& image,int depth,int quality,HevcPreset preset){
  using namespace codec::hevc;
  if(depth!=8 && depth!=10)throw std::invalid_argument("base depth must be 8 or 10");
  const auto grid=tile_grid(image.width,image.height);
  const EncodeParams params{quality,depth==10,preset==HevcPreset::Medium,{12,13,1}};
  return encode_picture(grid,params,[&](std::size_t index,YuvTile& tile){
    rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
      for(unsigned i=0;i<count;++i)for(unsigned c=0;c<3;++c)row[i*3+c]=srgb_oetf(image.at(x+i,y,c));
    },1,true,tile);
  });
}
codec::hevc::EncodedSequence encode_gain(const FloatImage& image,HevcPreset preset){
  using namespace codec::hevc;
  // apple_strict rejects multichannel metadata before any encoding. Never
  // silently discard authored channels at this lower boundary either.
  if(image.channels!=1)throw std::invalid_argument("Adaptive HEIC requires a single-channel gain map");
  const auto grid=tile_grid(image.width,image.height);
  const EncodeParams params{95,false,preset==HevcPreset::Medium,{2,2,1}};
  return encode_picture(grid,params,[&](std::size_t index,YuvTile& tile){
    luma_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
      for(unsigned i=0;i<count;++i)row[i]=image.at(x+i,y,0);
    },tile);
  });
}
HeifContentLight content_light(const FloatImage& hdr){
  std::vector<float> row_peak(hdr.height,0);std::vector<double> row_sum(hdr.height,0);
  parallel_for_rows(hdr.height,[&](unsigned y){
    float peak=0;double sum=0;
    for(unsigned x=0;x<hdr.width;++x){
      const auto rgb=p3_to_rec2020(hdr.at(x,y,0),hdr.at(x,y,1),hdr.at(x,y,2));
      const float light=std::max({0.0F,rgb[0],rgb[1],rgb[2]});peak=std::max(peak,light);sum+=light;
    }
    row_peak[y]=peak;row_sum[y]=sum;
  });
  const auto clamp=[](double nits){return static_cast<std::uint16_t>(std::clamp(std::ceil(nits),0.0,10000.0));};
  const double count=double(hdr.width)*hdr.height;
  return {clamp(*std::max_element(row_peak.begin(),row_peak.end())*kReferenceWhiteNits),
          clamp(std::accumulate(row_sum.begin(),row_sum.end(),0.0)*kReferenceWhiteNits/count)};
}
} // namespace

std::vector<std::uint8_t> encode_adaptive_heic(const GainMapResult& images,
    const PhotoMetadata& metadata,int quality,int depth,HevcPreset preset){
  validate_gain_map_metadata(images.metadata,GainMapWriterProfile::apple_strict);
  auto base=encode_base(images.base_linear,depth,quality,preset);
  auto gain=encode_gain(images.gain_map,preset);
  const auto icc=codec::display_p3_profile();
  HeifEncodedImage b{base,images.base_linear.width,images.base_linear.height,{},std::nullopt,icc};
  HeifEncodedImage g{gain,images.gain_map.width,images.gain_map.height,{2,2,1,true},std::nullopt,{}};
  HeifWriteOptions options;options.gain_metadata=images.metadata;
  options.exif=make_minimal_exif(metadata);options.xmp=make_xmp(metadata,images.headroom_stops,true);
  return write_heif(b,&g,options);
}
std::vector<std::uint8_t> encode_hdr_heic(const PhotoRenditions& images,
    const PhotoMetadata& metadata,int quality,HdrEncoding encoding,HevcPreset preset){
  using namespace codec::hevc;
  if(encoding!=HdrEncoding::Pq && encoding!=HdrEncoding::Hlg)
    throw std::invalid_argument("encode_hdr_heic requires PQ or HLG");
  const auto& hdr=images.hdr;const auto grid=tile_grid(hdr.width,hdr.height);
  const int transfer=encoding==HdrEncoding::Pq?16:18;
  const EncodeParams params{quality,true,preset==HevcPreset::Medium,{9,transfer,9}};
  auto coded=encode_picture(grid,params,[&](std::size_t index,YuvTile& tile){
    rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
      for(unsigned i=0;i<count;++i){
        const auto rgb=p3_to_rec2020(hdr.at(x+i,y,0),hdr.at(x+i,y,1),hdr.at(x+i,y,2));
        const std::array<float,3> linear{std::max(0.0F,rgb[0]),std::max(0.0F,rgb[1]),std::max(0.0F,rgb[2])};
        const auto encoded=encoding==HdrEncoding::Pq?std::array<float,3>{pq_oetf(linear[0]),pq_oetf(linear[1]),pq_oetf(linear[2])}:hlg_encode(linear);
        std::copy(encoded.begin(),encoded.end(),row+i*3);
      }
    },9,true,tile);
  });
  HeifEncodedImage image{coded,hdr.width,hdr.height,{9,static_cast<std::uint16_t>(transfer),9,true},content_light(hdr),{}};
  HeifWriteOptions options;options.exif=make_minimal_exif(metadata);
  options.xmp=make_xmp(metadata,images.stats.headroom_stops,false);
  return write_heif(image,nullptr,options);
}

void verify_heic_decodable(const std::vector<std::uint8_t>& bytes) {
  // Every check below already passed on a file that macOS ImageIO refused to
  // recognise as carrying a gain map at all (gate T2, 2026-08-09,
  // HyperDR_Model/reports/macos-t2-container-finding.md). Structural
  // self-consistency was never the same property as being readable by an
  // independent decoder, so the three conformance requirements that file lacked
  // are gated here as well, where they constrain what this writer emits.
  const auto inspection = inspect_heif(bytes);
  const bool auxiliary_declared =
      inspection.gain_map_auxiliary_type == "urn:iso:std:iso:ts:21496:-1";
  if (!inspection.structurally_valid || !inspection.has_heic_brand ||
      !inspection.has_tmap_brand || !inspection.has_tmap_item ||
      !inspection.has_dimg_reference || !inspection.has_altr_group ||
      !inspection.has_data_information || !inspection.gain_map_has_auxl_reference ||
      !auxiliary_declared) {
    // inspect_heif reports a failed check as a cleared flag and puts the reason
    // in `errors`, so a message built only from the flags describes the symptom
    // and hides the cause. A rejected gain-map payload, for instance, clears
    // structurally_valid and used to surface as nothing but "failed semantic
    // structure verification" -- true, and no help at all in finding out why.
    std::string reason = "Adaptive HDR HEIC failed semantic structure verification:";
    const auto note = [&reason](bool ok, const char* what) {
      if (!ok) reason += std::string(" no ") + what + ";";
    };
    note(inspection.has_heic_brand, "heic brand");
    note(inspection.has_tmap_brand, "tmap brand");
    note(inspection.has_tmap_item, "tmap item");
    note(inspection.has_dimg_reference, "dimg reference");
    note(inspection.has_altr_group, "altr group");
    note(inspection.has_data_information, "dinf box");
    note(inspection.gain_map_has_auxl_reference, "auxl reference from the gain map");
    note(auxiliary_declared, "ISO 21496-1 auxiliary type on the gain map");
    for (const auto& error : inspection.errors) reason += " " + error + ";";
    if (inspection.errors.empty() && inspection.structurally_valid) {
      reason += " no further detail was reported";
    }
    throw std::runtime_error(reason);
  }
  (void)parse_tmap_payload(extract_tmap_payload(bytes));
  const auto references = find_tmap_references(bytes);

  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate verification context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read Adaptive HDR HEIC");

  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  validate_base_profile(primary.get());
  if (heif_image_handle_get_item_id(primary.get()) != references.base_id) {
    throw std::runtime_error("tmap base reference is not the primary image");
  }

  const bool wide = heif_image_handle_get_luma_bits_per_pixel(primary.get()) > 8;
  heif_image* base_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &base_raw, heif_colorspace_RGB,
                               wide ? heif_chroma_interleaved_RRGGBB_LE
                                    : heif_chroma_interleaved_RGB,
                               nullptr),
             "decode SDR base");
  std::unique_ptr<heif_image, ImageDeleter> base(base_raw);
  const int base_width = heif_image_get_width(base.get(), heif_channel_interleaved);
  const int base_height = heif_image_get_height(base.get(), heif_channel_interleaved);
  if (base_width <= 0 || base_height <= 0) {
    throw std::runtime_error("decoded SDR base has invalid dimensions");
  }

  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context.get(), references.gain_id,
                                           &gain_handle_raw),
             "get Gain Map image handle");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  heif_color_profile_nclx* gain_profile_raw = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(
                 gain_handle.get(), &gain_profile_raw),
             "get Gain Map nclx");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      gain_profile(gain_profile_raw, &heif_nclx_color_profile_free);
  if (gain_profile->color_primaries != heif_color_primaries_unspecified ||
      gain_profile->transfer_characteristics !=
          heif_transfer_characteristic_unspecified ||
      gain_profile->matrix_coefficients !=
          heif_matrix_coefficients_ITU_R_BT_709_5 ||
      gain_profile->full_range_flag != 1) {
    throw std::runtime_error("Gain Map nclx must be 2/2/BT.709/full-range");
  }

  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw,
                               heif_colorspace_YCbCr, heif_chroma_420, nullptr),
             "decode Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain(gain_raw);
  const int gain_width = heif_image_get_width(gain.get(), heif_channel_Y);
  const int gain_height = heif_image_get_height(gain.get(), heif_channel_Y);
  if (gain_width <= 0 || gain_height <= 0 || gain_width > base_width ||
      gain_height > base_height ||
      heif_image_get_bits_per_pixel_range(gain.get(), heif_channel_Y) != 8) {
    throw std::runtime_error("decoded Gain Map has invalid dimensions or depth");
  }
  int y_stride = 0;
  if (!heif_image_get_plane_readonly(gain.get(), heif_channel_Y, &y_stride) ||
      y_stride < gain_width) {
    throw std::runtime_error("decoded Gain Map luma plane is unavailable");
  }
}

void verify_heic_decodable(const std::vector<std::uint8_t>& bytes,
                           HdrEncoding encoding) {
  if (encoding == HdrEncoding::Adaptive) {
    verify_heic_decodable(bytes);
    return;
  }
  const auto inspection = inspect_heif(bytes);
  if (!inspection.structurally_valid || !inspection.has_heic_brand ||
      inspection.has_tmap_item) {
    throw std::runtime_error("BT.2100 HEIC failed semantic structure verification");
  }
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HDR verification context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read BT.2100 HEIC");
  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get BT.2100 primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);

  heif_color_profile_nclx* profile_raw = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(primary.get(), &profile_raw),
             "get BT.2100 nclx");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      profile(profile_raw, &heif_nclx_color_profile_free);
  const auto expected_transfer = encoding == HdrEncoding::Pq
      ? heif_transfer_characteristic_ITU_R_BT_2100_0_PQ
      : heif_transfer_characteristic_ITU_R_BT_2100_0_HLG;
  if (profile->color_primaries !=
          heif_color_primaries_ITU_R_BT_2020_2_and_2100_0 ||
      profile->transfer_characteristics != expected_transfer ||
      profile->matrix_coefficients !=
          heif_matrix_coefficients_ITU_R_BT_2020_2_non_constant_luminance ||
      profile->full_range_flag != 1) {
    throw std::runtime_error("BT.2100 HEIC has incorrect nclx signalling");
  }
  heif_content_light_level light{};
  if (!heif_image_handle_get_content_light_level(primary.get(), &light)) {
    throw std::runtime_error("BT.2100 HEIC lacks content-light metadata");
  }

  std::unique_ptr<heif_decoding_options, DecodingOptionsDeleter> options(
      heif_decoding_options_alloc());
  if (!options) throw std::runtime_error("cannot allocate HDR decoding options");
  options->output_image_nclx_profile_passthrough = 1;
  heif_image* decoded_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &decoded_raw, heif_colorspace_RGB,
                               heif_chroma_interleaved_RRGGBB_LE, options.get()),
             "decode BT.2100 HDR image");
  std::unique_ptr<heif_image, ImageDeleter> decoded(decoded_raw);
  if (heif_image_get_width(decoded.get(), heif_channel_interleaved) <= 0 ||
      heif_image_get_height(decoded.get(), heif_channel_interleaved) <= 0 ||
      heif_image_get_bits_per_pixel_range(decoded.get(), heif_channel_interleaved) != 10) {
    throw std::runtime_error("decoded BT.2100 image is not valid 10-bit RGB");
  }
}

void verify_heic_decodable(const std::filesystem::path& input) {
  const auto bytes = read_binary_file(input);
  const auto inspection = inspect_heif(bytes);
  if (inspection.has_tmap_brand || inspection.has_tmap_item) {
    verify_heic_decodable(bytes);
    return;
  }
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HEIC detection context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read HEIC for HDR mode detection");
  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get image for HDR mode detection");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  heif_color_profile_nclx* profile_raw = nullptr;
  const auto profile_error =
      heif_image_handle_get_nclx_color_profile(primary.get(), &profile_raw);
  if (profile_error.code != heif_error_Ok || profile_raw == nullptr) {
    if (profile_raw) heif_nclx_color_profile_free(profile_raw);
    throw std::runtime_error(
        "HEIC is neither Adaptive HDR nor nclx-signalled PQ/HLG");
  }
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      profile(profile_raw, &heif_nclx_color_profile_free);
  if (profile->transfer_characteristics == heif_transfer_characteristic_ITU_R_BT_2100_0_PQ) {
    verify_heic_decodable(bytes, HdrEncoding::Pq);
  } else if (profile->transfer_characteristics ==
             heif_transfer_characteristic_ITU_R_BT_2100_0_HLG) {
    verify_heic_decodable(bytes, HdrEncoding::Hlg);
  } else {
    throw std::runtime_error("HEIC is neither Adaptive HDR, PQ, nor HLG");
  }
}

namespace {

struct DecodedGainMapHeic {
  FloatImage base;
  FloatImage gain;
  GainMapMetadata metadata;
};

DecodedGainMapHeic decode_gain_map_heic_components(
    const std::filesystem::path& input) {
  const auto bytes = read_binary_file(input);
  const auto metadata = parse_tmap_payload(extract_tmap_payload(bytes));
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate libheif context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read Adaptive HDR HEIC");

  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  validate_base_profile(primary.get());
  const bool wide_base = heif_image_handle_get_luma_bits_per_pixel(primary.get()) > 8;
  heif_image* base_raw = nullptr;
  check_heif(heif_decode_image(
                 primary.get(), &base_raw, heif_colorspace_RGB,
                 wide_base ? heif_chroma_interleaved_RRGGBB_LE
                           : heif_chroma_interleaved_RGB,
                 nullptr),
             "decode SDR base");
  std::unique_ptr<heif_image, ImageDeleter> base_image(base_raw);

  // The Gain Map is the second dimg reference of the tmap item; scanning for
  // any decodable non-primary item can select a hidden grid tile instead.
  const auto references = find_tmap_references(bytes);
  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context.get(), references.gain_id,
                                           &gain_handle_raw),
             "get Gain Map image handle");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  validate_gain_profile(gain_handle.get());
  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw,
                               heif_colorspace_undefined, heif_chroma_undefined,
                               nullptr),
             "decode Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);

  const auto width = static_cast<std::uint32_t>(
      heif_image_get_width(base_image.get(), heif_channel_interleaved));
  const auto height = static_cast<std::uint32_t>(
      heif_image_get_height(base_image.get(), heif_channel_interleaved));
  const auto gain_width = static_cast<std::uint32_t>(
      heif_image_get_width(gain_image.get(), heif_channel_Y));
  const auto gain_height = static_cast<std::uint32_t>(
      heif_image_get_height(gain_image.get(), heif_channel_Y));
  FloatImage base(width, height, 3), gain(gain_width, gain_height, 1);
  int base_stride = 0;
  int gain_stride = 0;
  const auto* base_plane = heif_image_get_plane_readonly(
      base_image.get(), heif_channel_interleaved, &base_stride);
  const auto* gain_plane = heif_image_get_plane_readonly(
      gain_image.get(), heif_channel_Y, &gain_stride);
  if (!base_plane || !gain_plane) {
    throw std::runtime_error("decoded HEIC plane is missing");
  }
  const int base_bits = heif_image_get_bits_per_pixel_range(
      base_image.get(), heif_channel_interleaved);
  const int gain_bits = heif_image_get_bits_per_pixel_range(
      gain_image.get(), heif_channel_Y);
  const float base_max =
      static_cast<float>((1U << std::min(base_bits, 16)) - 1U);
  const float gain_max =
      static_cast<float>((1U << std::min(gain_bits, 16)) - 1U);
  for (std::uint32_t y = 0; y < height; ++y) {
    check_cancelled();
    if (base_bits > 8) {
      const auto* row = reinterpret_cast<const std::uint16_t*>(
          base_plane + static_cast<std::size_t>(y) * base_stride);
      for (std::uint32_t x = 0; x < width; ++x) {
        for (unsigned c = 0; c < 3; ++c) {
          base.at(x, y, c) =
              srgb_eotf(row[x * 3 + c] / base_max);
        }
      }
    } else {
      const auto* row =
          base_plane + static_cast<std::size_t>(y) * base_stride;
      for (std::uint32_t x = 0; x < width; ++x) {
        for (unsigned c = 0; c < 3; ++c) {
          base.at(x, y, c) = srgb_eotf(row[x * 3 + c] / base_max);
        }
      }
    }
  }
  for (std::uint32_t y = 0; y < gain_height; ++y) {
    check_cancelled();
    if (gain_bits <= 8) {
      for (std::uint32_t x = 0; x < gain_width; ++x) {
        gain.at(x, y, 0) =
            gain_plane[static_cast<std::size_t>(y) * gain_stride + x] /
            gain_max;
      }
    } else {
      const auto* row = reinterpret_cast<const std::uint16_t*>(
          gain_plane + static_cast<std::size_t>(y) * gain_stride);
      for (std::uint32_t x = 0; x < gain_width; ++x) {
        gain.at(x, y, 0) = row[x] / gain_max;
      }
    }
  }
  return {std::move(base), std::move(gain), metadata};
}

}  // namespace

void reconstruct_heic_to_tiff(const std::filesystem::path& input,
                              const std::filesystem::path& output) {
  const auto bytes = read_binary_file(input);
  const auto metadata = parse_tmap_payload(extract_tmap_payload(bytes));
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate libheif context");
  check_heif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr),
             "read Adaptive HDR HEIC");

  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw), "get primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  validate_base_profile(primary.get());
  const bool wide_base = heif_image_handle_get_luma_bits_per_pixel(primary.get()) > 8;
  heif_image* base_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &base_raw, heif_colorspace_RGB,
                               wide_base ? heif_chroma_interleaved_RRGGBB_LE : heif_chroma_interleaved_RGB,
                               nullptr), "decode SDR base");
  std::unique_ptr<heif_image, ImageDeleter> base_image(base_raw);

  // The Gain Map is the second dimg reference of the tmap item; scanning for "any
  // decodable non-primary item" would wrongly pick a hidden grid tile instead.
  const auto references = find_tmap_references(bytes);
  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context.get(), references.gain_id, &gain_handle_raw),
             "get Gain Map image handle");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  validate_gain_profile(gain_handle.get());
  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw, heif_colorspace_undefined,
                               heif_chroma_undefined, nullptr), "decode Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);

  const auto width = static_cast<std::uint32_t>(heif_image_get_width(base_image.get(), heif_channel_interleaved));
  const auto height = static_cast<std::uint32_t>(heif_image_get_height(base_image.get(), heif_channel_interleaved));
  const auto gain_width = static_cast<std::uint32_t>(heif_image_get_width(gain_image.get(), heif_channel_Y));
  const auto gain_height = static_cast<std::uint32_t>(heif_image_get_height(gain_image.get(), heif_channel_Y));
  FloatImage base(width, height, 3), gain(gain_width, gain_height, 1);
  int base_stride = 0, gain_stride = 0;
  const auto* base_plane = heif_image_get_plane_readonly(base_image.get(), heif_channel_interleaved, &base_stride);
  const auto* gain_plane = heif_image_get_plane_readonly(gain_image.get(), heif_channel_Y, &gain_stride);
  if (!base_plane || !gain_plane) throw std::runtime_error("decoded HEIC plane is missing");
  const int base_bits = heif_image_get_bits_per_pixel_range(base_image.get(), heif_channel_interleaved);
  const int gain_bits = heif_image_get_bits_per_pixel_range(gain_image.get(), heif_channel_Y);
  const float base_max = static_cast<float>((1U << std::min(base_bits, 16)) - 1U);
  const float gain_max = static_cast<float>((1U << std::min(gain_bits, 16)) - 1U);
  for (std::uint32_t y = 0; y < height; ++y) {
    check_cancelled();
    if (base_bits > 8) {
      const auto* row = reinterpret_cast<const std::uint16_t*>(base_plane + static_cast<std::size_t>(y) * base_stride);
      for (std::uint32_t x = 0; x < width; ++x)
        for (unsigned c = 0; c < 3; ++c) base.at(x, y, c) = srgb_eotf(row[x * 3 + c] / base_max);
    } else {
      const auto* row = base_plane + static_cast<std::size_t>(y) * base_stride;
      for (std::uint32_t x = 0; x < width; ++x)
        for (unsigned c = 0; c < 3; ++c) base.at(x, y, c) = srgb_eotf(row[x * 3 + c] / base_max);
    }
  }
  for (std::uint32_t y = 0; y < gain_height; ++y) {
    check_cancelled();
    if (gain_bits <= 8) {
      for (std::uint32_t x = 0; x < gain_width; ++x) gain.at(x, y, 0) = gain_plane[static_cast<std::size_t>(y) * gain_stride + x] / gain_max;
    } else {
      const auto* row = reinterpret_cast<const std::uint16_t*>(gain_plane + static_cast<std::size_t>(y) * gain_stride);
      for (std::uint32_t x = 0; x < gain_width; ++x) gain.at(x, y, 0) = row[x] / gain_max;
    }
  }
  const float stops = static_cast<float>(metadata.alternate_headroom.numerator) /
                      static_cast<float>(metadata.alternate_headroom.denominator);
  const auto hdr = reconstruct_gain_map(base, gain, metadata, stops);

  auto le16 = [](std::vector<std::uint8_t>& out, std::uint16_t v) {
    out.push_back(static_cast<std::uint8_t>(v)); out.push_back(static_cast<std::uint8_t>(v >> 8));
  };
  auto le32 = [](std::vector<std::uint8_t>& out, std::uint32_t v) {
    out.push_back(static_cast<std::uint8_t>(v)); out.push_back(static_cast<std::uint8_t>(v >> 8));
    out.push_back(static_cast<std::uint8_t>(v >> 16)); out.push_back(static_cast<std::uint8_t>(v >> 24));
  };
  const auto linear_icc = codec::display_p3_profile(true);
  constexpr std::uint16_t entry_count = 12;
  const std::uint32_t ifd_end = 8 + 2 + entry_count * 12 + 4;
  const std::uint32_t bits_offset = ifd_end;
  const std::uint32_t sample_format_offset = bits_offset + 6;
  const std::uint32_t icc_offset = sample_format_offset + 6;
  const std::uint32_t pixels_offset =
      icc_offset + static_cast<std::uint32_t>(linear_icc.size()) +
      static_cast<std::uint32_t>(linear_icc.size() & 1U);
  const std::uint64_t byte_count64 =
      static_cast<std::uint64_t>(width) * height * 3U * sizeof(float);
  if (byte_count64 > std::numeric_limits<std::uint32_t>::max()) {
    throw std::runtime_error("reconstructed TIFF exceeds classic TIFF limits");
  }
  const auto byte_count = static_cast<std::uint32_t>(byte_count64);

  std::vector<std::uint8_t> tiff{'I', 'I'};
  tiff.reserve(static_cast<std::size_t>(pixels_offset) + byte_count);
  le16(tiff, 42); le32(tiff, 8);
  le16(tiff, entry_count);
  auto entry = [&](std::uint16_t tag, std::uint16_t type, std::uint32_t count, std::uint32_t value) {
    le16(tiff, tag); le16(tiff, type); le32(tiff, count); le32(tiff, value);
  };
  entry(256, 4, 1, width);
  entry(257, 4, 1, height);
  entry(258, 3, 3, bits_offset);
  entry(259, 3, 1, 1);
  entry(262, 3, 1, 2);
  entry(273, 4, 1, pixels_offset);
  entry(277, 3, 1, 3);
  entry(278, 4, 1, height);
  entry(279, 4, 1, byte_count);
  entry(284, 3, 1, 1);
  entry(339, 3, 3, sample_format_offset);
  entry(34675, 7, static_cast<std::uint32_t>(linear_icc.size()), icc_offset);
  le32(tiff, 0);
  le16(tiff, 32); le16(tiff, 32); le16(tiff, 32);
  le16(tiff, 3); le16(tiff, 3); le16(tiff, 3);
  tiff.insert(tiff.end(), linear_icc.begin(), linear_icc.end());
  if (tiff.size() & 1U) tiff.push_back(0);
  for (const float value : hdr.pixels) {
    const float finite = std::isfinite(value) ? std::max(0.0F, value) : 0.0F;
    le32(tiff, std::bit_cast<std::uint32_t>(finite));
  }
  write_binary_file_atomic(output, tiff, true);
}

DisplayCurveResult compare_gain_map_heic_curve(
    const std::filesystem::path& reference,
    const std::filesystem::path& candidate,
    const std::vector<float>& display_headroom_stops) {
  if (display_headroom_stops.empty()) {
    throw std::invalid_argument("display curve requires at least one headroom");
  }
  auto reference_components = decode_gain_map_heic_components(reference);
  auto candidate_components = decode_gain_map_heic_components(candidate);
  if (reference_components.base.width != candidate_components.base.width ||
      reference_components.base.height != candidate_components.base.height ||
      reference_components.base.channels != candidate_components.base.channels) {
    throw std::invalid_argument("reference and candidate base images disagree");
  }

  DisplayCurveResult result;
  result.points.reserve(display_headroom_stops.size());
  for (const float headroom : display_headroom_stops) {
    if (!std::isfinite(headroom) || headroom < 0.0F) {
      throw std::invalid_argument("display headroom must be finite and non-negative");
    }
    ReconstructionStats reference_stats{};
    ReconstructionStats candidate_stats{};
    const auto reference_render = reconstruct_gain_map(
        reference_components.base, reference_components.gain,
        reference_components.metadata, headroom, &reference_stats);
    const auto candidate_render = reconstruct_gain_map(
        candidate_components.base, candidate_components.gain,
        candidate_components.metadata, headroom, &candidate_stats);
    if (reference_render.pixels.size() != candidate_render.pixels.size()) {
      throw std::invalid_argument("reference and candidate render sizes disagree");
    }
    long double sum = 0.0L;
    long double squared_sum = 0.0L;
    double maximum = 0.0;
    for (std::size_t index = 0; index < reference_render.pixels.size(); ++index) {
      const float reference_value = reference_render.pixels[index];
      const float candidate_value = candidate_render.pixels[index];
      if (!std::isfinite(reference_value) || !std::isfinite(candidate_value)) {
        throw std::runtime_error("display reconstruction produced non-finite pixels");
      }
      const double difference =
          std::abs(static_cast<double>(candidate_value) - reference_value);
      sum += difference;
      squared_sum += difference * difference;
      maximum = std::max(maximum, difference);
    }
    const auto count = static_cast<long double>(reference_render.pixels.size());
    DisplayCurvePoint point;
    point.headroom_stops = headroom;
    point.mae_linear_p3 = static_cast<double>(sum / count);
    point.mse_linear_p3 = static_cast<double>(squared_sum / count);
    point.max_abs_error_linear_p3 = maximum;
    point.total_values = reference_stats.total_values;
    point.reference_clamp_values = reference_stats.clamp_values;
    point.candidate_clamp_values = candidate_stats.clamp_values;
    point.total_pixels = reference_stats.total_pixels;
    point.reference_clamp_pixels = reference_stats.clamp_pixels;
    point.candidate_clamp_pixels = candidate_stats.clamp_pixels;
    result.points.push_back(point);
  }
  return result;
}
}  // namespace hyperdr

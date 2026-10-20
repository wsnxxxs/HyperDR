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

#include "hyperdr/container/heif_reader.hpp"
#include "internal/heif_decoder.hpp"
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

// The Adaptive base is an SDR picture: either an ICC (Display P3) profile or an
// nclx-only BT.709/sRGB description, as Apple's files carry. When both exist
// the nclx must still be consistent with an SDR full-range base.
void validate_base_profile(const HeifImagePlan& base) {
  const bool has_icc = !base.icc.empty();
  if (!has_icc || !base.color) return;
  const auto& c = *base.color;
  const bool valid = (c.primaries == 12 || c.primaries == 1 || c.primaries == 2) &&
                     (c.transfer == 13 || c.transfer == 1 || c.transfer == 2) &&
                     (c.matrix == 1 || c.matrix == 2) && c.full_range;
  if (!valid) throw std::runtime_error("SDR base lacks a usable ICC or nclx SDR profile");
}
// Apple's gain-map item is often deliberately unprofiled; the metadata carries
// the ISO interpretation. HyperDR's own files carry unspecified/BT.709 full
// range, so a profile that is present is checked rather than ignored.
bool gain_profile_valid(const HeifImagePlan& gain) {
  if (!gain.color) return true;
  const auto& c = *gain.color;
  return c.primaries == 2 && c.transfer == 2 && c.matrix == 1 && c.full_range;
}
void validate_gain_profile(const HeifImagePlan& gain) {
  if (!gain_profile_valid(gain)) throw std::runtime_error("Gain Map lacks required nclx 2/2/1/full");
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
codec::hevc::EncodedSequence encode_base(const FloatImage& image,int depth,int quality){
  using namespace codec::hevc;
  if(depth!=8 && depth!=10)throw std::invalid_argument("base depth must be 8 or 10");
  const auto grid=tile_grid(image.width,image.height);
  const EncodeParams params{quality,depth==10,{12,13,1}};
  return encode_picture(grid,params,[&](std::size_t index,YuvTile& tile){
    rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
      for(unsigned i=0;i<count;++i)for(unsigned c=0;c<3;++c)row[i*3+c]=srgb_oetf(image.at(x+i,y,c));
    },1,false,tile);
  });
}
codec::hevc::EncodedSequence encode_gain(const FloatImage& image,int quality,bool frame){
  using namespace codec::hevc;
  // apple_strict rejects multichannel metadata before any encoding. Never
  // silently discard authored channels at this lower boundary either.
  if(image.channels!=1)throw std::invalid_argument("Adaptive HEIC requires a single-channel gain map");
  const auto grid=tile_grid(image.width,image.height);
  const EncodeParams params{quality,false,{2,2,1},
      frame?QualityRole::FramedGain:QualityRole::Gain};
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
    const PhotoMetadata& metadata,int quality,int depth){
  validate_gain_map_metadata(images.metadata,GainMapWriterProfile::apple_strict);
  auto base=encode_base(images.base_linear,depth,quality);
  auto gain=encode_gain(images.gain_map,quality,images.presentation_frame);
  const auto icc=codec::display_p3_profile();
  HeifEncodedImage b{base,images.base_linear.width,images.base_linear.height,{},std::nullopt,icc};
  HeifEncodedImage g{gain,images.gain_map.width,images.gain_map.height,{2,2,1,true},std::nullopt,{}};
  HeifWriteOptions options;options.gain_metadata=images.metadata;
  options.exif=make_minimal_exif(metadata);options.xmp=make_xmp(metadata,images.headroom_stops,true);
  return write_heif(b,&g,options);
}
std::vector<std::uint8_t> encode_hdr_heic(const PhotoRenditions& images,
    const PhotoMetadata& metadata,int quality,HdrEncoding encoding){
  using namespace codec::hevc;
  if(encoding!=HdrEncoding::Pq && encoding!=HdrEncoding::Hlg)
    throw std::invalid_argument("encode_hdr_heic requires PQ or HLG");
  const auto& hdr=images.hdr;const auto grid=tile_grid(hdr.width,hdr.height);
  const int transfer=encoding==HdrEncoding::Pq?16:18;
  const EncodeParams params{quality,true,{9,transfer,9}};
  auto coded=encode_picture(grid,params,[&](std::size_t index,YuvTile& tile){
    rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row){
      for(unsigned i=0;i<count;++i){
        const auto rgb=p3_to_rec2020(hdr.at(x+i,y,0),hdr.at(x+i,y,1),hdr.at(x+i,y,2));
        const std::array<float,3> linear{std::max(0.0F,rgb[0]),std::max(0.0F,rgb[1]),std::max(0.0F,rgb[2])};
        const auto encoded=encoding==HdrEncoding::Pq?std::array<float,3>{pq_oetf(linear[0]),pq_oetf(linear[1]),pq_oetf(linear[2])}:hlg_encode(linear);
        std::copy(encoded.begin(),encoded.end(),row+i*3);
      }
    },9,false,tile);
  });
  HeifEncodedImage image{coded,hdr.width,hdr.height,{9,static_cast<std::uint16_t>(transfer),9,true},content_light(hdr),{}};
  HeifWriteOptions options;options.exif=make_minimal_exif(metadata);
  options.xmp=make_xmp(metadata,images.stats.headroom_stops,false);
  return write_heif(image,nullptr,options);
}

std::vector<std::uint8_t> encode_heic_rows(const EncodingRows& base,const EncodingRows& codes,
    const GainMapMetadata& metadata,float headroom,const PhotoMetadata& photo,
    OutputEncoding encoding,int quality,int depth,bool frame) {
  using namespace codec::hevc;
  const auto grid=tile_grid(base.width,base.height);
  auto picture=[&](const EncodingRows& rows,const EncodeParams& parameters,bool luma,bool hdr) {
    FloatImage slab(rows.width,std::min(kTileSize,rows.height),rows.channels);
    unsigned first=rows.height;
    return encode(grid.count(),[&](std::size_t index,YuvTile& tile) {
      const auto block=unsigned(index/grid.columns)*kTileSize;
      if(block!=first) {
        first=block;const auto count=std::min(kTileSize,rows.height-first);
        for(unsigned y=0;y<count;++y) {
          check_cancelled();rows.read(first+y,std::span(slab.pixels).subspan(std::size_t(y)*rows.width*rows.channels,std::size_t(rows.width)*rows.channels));
        }
      }
      if(luma) {
        luma_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row) {
          std::copy_n(slab.pixels.data()+(std::size_t(y-first)*rows.width+x),count,row);
        },tile);
      } else {
        rgb_tile(grid,index,[&](unsigned y,unsigned x,unsigned count,float* row) {
          for(unsigned i=0;i<count;++i) {
            const auto offset=(std::size_t(y-first)*rows.width+x+i)*3;
            std::array<float,3> rgb{slab.pixels[offset],slab.pixels[offset+1],slab.pixels[offset+2]};
            if(hdr) {
              rgb=p3_to_rec2020(rgb[0],rgb[1],rgb[2]);
              for(auto& v:rgb)v=std::max(0.f,v);
              rgb=encoding==OutputEncoding::Pq?std::array<float,3>{pq_oetf(rgb[0]),pq_oetf(rgb[1]),pq_oetf(rgb[2])}:hlg_encode(rgb);
            } else for(auto& v:rgb)v=srgb_oetf(v);
            std::copy(rgb.begin(),rgb.end(),row+i*3);
          }
        },hdr?9:1,false,tile);
      }
    },parameters);
  };
  HeifWriteOptions options;options.exif=make_minimal_exif(photo);
  if(encoding==OutputEncoding::Adaptive) {
    validate_gain_map_metadata(metadata,GainMapWriterProfile::apple_strict);
    auto b=picture(base,{quality,depth==10,{12,13,1}},false,false);
    auto g=picture(codes,{quality,false,{2,2,1},frame?QualityRole::FramedGain:QualityRole::Gain},true,false);
    const auto icc=codec::display_p3_profile();
    HeifEncodedImage primary{b,base.width,base.height,{},std::nullopt,icc};
    HeifEncodedImage gain{g,base.width,base.height,{2,2,1,true},std::nullopt,{}};
    options.gain_metadata=metadata;options.xmp=make_xmp(photo,headroom,true);
    return write_heif(primary,&gain,options);
  }
  FloatImage b(base.width,1,3),g(base.width,1,codes.channels);
  EncodingRows hdr{base.width,base.height,3,[&](unsigned y,std::span<float> out) {
    base.read(y,b.pixels);codes.read(y,g.pixels);
    const auto reconstructed=reconstruct_gain_map(b,g,metadata,headroom);
    std::copy(reconstructed.pixels.begin(),reconstructed.pixels.end(),out.begin());
  }};
  std::vector<float> row(std::size_t(base.width)*3);
  float peak=0;double sum=0;
  for(unsigned y=0;y<base.height;++y) {
    hdr.read(y,row);double row_sum=0;
    for(unsigned x=0;x<base.width;++x) {
      const auto rgb=p3_to_rec2020(row[x*3],row[x*3+1],row[x*3+2]);
      const auto light=std::max({0.f,rgb[0],rgb[1],rgb[2]});peak=std::max(peak,light);row_sum+=light;
    }
    sum+=row_sum;
  }
  const auto clamp=[](double nits){return std::uint16_t(std::clamp(std::ceil(nits),0.,10000.));};
  const HeifContentLight light{clamp(peak*kReferenceWhiteNits),clamp(sum*kReferenceWhiteNits/(double(base.width)*base.height))};
  const int transfer=encoding==OutputEncoding::Pq?16:18;
  auto coded=picture(hdr,{quality,true,{9,transfer,9}},false,true);
  HeifEncodedImage primary{coded,base.width,base.height,{9,static_cast<std::uint16_t>(transfer),9,true},light,{}};
  options.xmp=make_xmp(photo,headroom,false);
  return write_heif(primary,nullptr,options);
}

void verify_heic_decodable(std::span<const std::uint8_t> bytes) {
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

  // Tiled: the written canvas may exceed what the raster budget can hold whole
  // (a 185 MP story card); verification only ever holds one coded picture.
  const auto file = read_heif(bytes);
  const auto plan = file.resolve_gain_map(HeifCanvas::Tiled);
  if (!plan) throw std::runtime_error("Adaptive HDR HEIC lacks a gain map");
  if (plan->base.item_id != references.base_id) {
    throw std::runtime_error("tmap base reference is not the primary image");
  }
  validate_base_profile(plan->base);
  if (!plan->gain.color || !gain_profile_valid(plan->gain)) {
    throw std::runtime_error("Gain Map nclx must be 2/2/BT.709/full-range");
  }
  if (plan->gain.width > plan->base.width || plan->gain.height > plan->base.height ||
      plan->gain.config.bit_depth != 8) {
    throw std::runtime_error("decoded Gain Map has invalid dimensions or depth");
  }
  codec::verify_heif_tiles(file, plan->base);
  codec::verify_heif_tiles(file, plan->gain);
}

void verify_heic_decodable(std::span<const std::uint8_t> bytes,
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
  const auto file = read_heif(bytes);
  const auto plan = file.resolve_image(0, HeifCanvas::Tiled);
  const int expected_transfer = encoding == HdrEncoding::Pq ? 16 : 18;
  if (!plan.color || plan.color->primaries != 9 || plan.color->transfer != expected_transfer ||
      plan.color->matrix != 9 || !plan.color->full_range) {
    throw std::runtime_error("BT.2100 HEIC has incorrect nclx signalling");
  }
  if (!plan.light) throw std::runtime_error("BT.2100 HEIC lacks content-light metadata");
  if (plan.config.bit_depth != 10 || plan.config.chroma_format == 0) {
    throw std::runtime_error("BT.2100 HEIC is not 10-bit colour HEVC");
  }
  codec::verify_heif_tiles(file, plan);
}

void verify_heic_decodable(const std::filesystem::path& input) {
  const auto bytes = read_binary_file(input);
  const auto inspection = inspect_heif(bytes);
  if (inspection.has_tmap_brand || inspection.has_tmap_item) {
    verify_heic_decodable(bytes);
    return;
  }
  const auto plan = read_heif(bytes).resolve_image(0, HeifCanvas::Tiled);
  if (!plan.color) {
    throw std::runtime_error(
        "HEIC is neither Adaptive HDR nor nclx-signalled PQ/HLG");
  }
  if (plan.color->transfer == 16) {
    verify_heic_decodable(bytes, HdrEncoding::Pq);
  } else if (plan.color->transfer == 18) {
    verify_heic_decodable(bytes, HdrEncoding::Hlg);
  } else {
    throw std::runtime_error("HEIC is neither Adaptive HDR, PQ, nor HLG");
  }
}

namespace {
// Lenient about unprofiled gain maps (Apple's), strict about present profiles;
// the same decoding as the input path. Diagnostics see the whole canvas, never a
// reduced copy: when the planes they need do not fit the memory budget, the
// command stops with that figure instead of quietly working on fewer pixels.
struct OpenedAdaptive {
  std::vector<std::uint8_t> bytes;
  HeifFile file;
  HeifGainMapPlan plan;
  [[nodiscard]] std::uint64_t pixels() const {
    return std::uint64_t(plan.base.width) * plan.base.height;
  }
};
std::unique_ptr<OpenedAdaptive> open_adaptive(const std::filesystem::path& input) {
  // HeifFile and its plans borrow the bytes, so they are filled in place.
  auto opened = std::make_unique<OpenedAdaptive>();
  opened->bytes = read_binary_file(input);
  opened->file = read_heif(opened->bytes);
  auto plan = opened->file.resolve_gain_map(HeifCanvas::Tiled);
  if (!plan || !plan->metadata) throw std::runtime_error("Adaptive HDR HEIC lacks a gain map");
  validate_base_profile(plan->base);
  validate_gain_profile(plan->gain);
  opened->plan = std::move(*plan);
  return opened;
}
// `bytes_per_pixel` is what the command holds per canvas pixel, summed over
// every file it keeps in memory at once (`pixels` is that total).
void require_whole_canvas(const OpenedAdaptive& shown, std::uint64_t pixels,
                          std::uint64_t bytes_per_pixel) {
  const auto budget = current_execution_config.memory_budget_bytes;
  if (budget && pixels > budget / bytes_per_pixel) {
    throw std::runtime_error("the whole " + std::to_string(shown.plan.base.width) + "x" +
                             std::to_string(shown.plan.base.height) + " canvas needs about " +
                             std::to_string(pixels * bytes_per_pixel >> 20) +
                             " MiB, over the memory budget of " + std::to_string(budget >> 20) +
                             " MiB; diagnostics do not work on a reduced copy");
  }
}
}  // namespace

void reconstruct_heic_to_tiff(const std::filesystem::path& input,
                              const std::filesystem::path& output) {
  const auto opened = open_adaptive(input);
  require_whole_canvas(*opened, opened->pixels(), 40);
  auto parts = codec::decode_heif_adaptive_parts(opened->file, opened->plan);
  const auto& metadata = parts.metadata;
  const std::uint32_t width = parts.base.width, height = parts.base.height;
  const float stops = static_cast<float>(metadata.alternate_headroom.numerator) /
                      static_cast<float>(metadata.alternate_headroom.denominator);
  const auto hdr = reconstruct_gain_map(parts.base, parts.gain, metadata, stops);

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
  // Both files are in memory together (about 26 B/px each: base float RGB, gain
  // plane, reconstruction and the comparison's share), so check the sum once,
  // before either is decoded.
  const auto reference_file = open_adaptive(reference);
  const auto candidate_file = open_adaptive(candidate);
  require_whole_canvas(*reference_file, reference_file->pixels() + candidate_file->pixels(), 26);
  auto reference_components =
      codec::decode_heif_adaptive_parts(reference_file->file, reference_file->plan);
  auto candidate_components =
      codec::decode_heif_adaptive_parts(candidate_file->file, candidate_file->plan);
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

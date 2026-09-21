#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <avif/avif.h>
#include <libheif/heif.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {
constexpr unsigned size = 32;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void check(heif_error e) { if (e.code != heif_error_Ok) throw std::runtime_error(e.message); }
void check(avifResult e) { if (e != AVIF_RESULT_OK) throw std::runtime_error(avifResultToString(e)); }
std::vector<unsigned char> rgba(bool premultiplied) {
  std::vector<unsigned char> pixels(size * size * 4);
  constexpr unsigned char alphas[]{0, 128, 255, 128};
  for (unsigned y=0; y<size; ++y) for (unsigned x=0; x<size; ++x) {
    const auto a=alphas[x/8];
    const auto i=(y*size+x)*4;
    // Deliberate hidden white at zero alpha must never appear in the result.
    for (unsigned c=0;c<3;++c) pixels[i+c]=premultiplied && a ? a : 255;
    pixels[i+3]=a;
  }
  return pixels;
}
void encode_avif(const std::filesystem::path& path, bool premultiplied) {
  std::unique_ptr<avifImage, decltype(&avifImageDestroy)> image(
      avifImageCreate(size,size,8,AVIF_PIXEL_FORMAT_YUV444), avifImageDestroy);
  image->colorPrimaries=AVIF_COLOR_PRIMARIES_BT709;
  image->transferCharacteristics=AVIF_TRANSFER_CHARACTERISTICS_SRGB;
  image->matrixCoefficients=AVIF_MATRIX_COEFFICIENTS_IDENTITY;
  image->yuvRange=AVIF_RANGE_FULL;
  image->alphaPremultiplied=premultiplied;
  auto pixels=rgba(premultiplied);
  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb,image.get());
  rgb.format=AVIF_RGB_FORMAT_RGBA;
  rgb.alphaPremultiplied=premultiplied;
  rgb.pixels=pixels.data(); rgb.rowBytes=size*4;
  check(avifImageRGBToYUV(image.get(),&rgb));
  std::unique_ptr<avifEncoder, decltype(&avifEncoderDestroy)> encoder(avifEncoderCreate(),avifEncoderDestroy);
  encoder->quality=encoder->qualityAlpha=AVIF_QUALITY_LOSSLESS;
  encoder->speed=AVIF_SPEED_FASTEST;
  encoder->maxThreads=1;
  avifRWData bytes=AVIF_DATA_EMPTY;
  check(avifEncoderWrite(encoder.get(),image.get(),&bytes));
  std::ofstream file(path,std::ios::binary);
  file.write(reinterpret_cast<const char*>(bytes.data),bytes.size);
  avifRWDataFree(&bytes);
  require(bool(file),"cannot write alpha AVIF fixture");
}
void encode_heif(const std::filesystem::path& path, bool premultiplied, bool adaptive=false) {
  std::unique_ptr<heif_context,decltype(&heif_context_free)> context(heif_context_alloc(),heif_context_free);
  heif_encoder* encoder_raw=nullptr;
  check(heif_context_get_encoder_for_format(context.get(),heif_compression_HEVC,&encoder_raw));
  std::unique_ptr<heif_encoder,decltype(&heif_encoder_release)> encoder(encoder_raw,heif_encoder_release);
  check(heif_encoder_set_lossless(encoder.get(),1));
  check(heif_encoder_set_parameter_string(encoder.get(),"chroma","444"));
  heif_image* image_raw=nullptr;
  check(heif_image_create(size,size,heif_colorspace_RGB,heif_chroma_interleaved_RGBA,&image_raw));
  std::unique_ptr<heif_image,decltype(&heif_image_release)> image(image_raw,heif_image_release);
  check(heif_image_add_plane(image.get(),heif_channel_interleaved,size,size,8));
  int stride=0;
  auto* plane=heif_image_get_plane(image.get(),heif_channel_interleaved,&stride);
  const auto pixels=rgba(premultiplied);
  for(unsigned y=0;y<size;++y) std::copy_n(pixels.data()+y*size*4,size*4,plane+y*stride);
  heif_image_set_premultiplied_alpha(image.get(),premultiplied);
  heif_color_profile_nclx nclx{};
  nclx.version=1;
  nclx.color_primaries=static_cast<heif_color_primaries>(1);
  nclx.transfer_characteristics=static_cast<heif_transfer_characteristics>(13);
  nclx.matrix_coefficients=static_cast<heif_matrix_coefficients>(0);
  nclx.full_range_flag=1;
  check(heif_image_set_nclx_color_profile(image.get(),&nclx));
  std::unique_ptr<heif_encoding_options,decltype(&heif_encoding_options_free)> options(
      heif_encoding_options_alloc(),heif_encoding_options_free);
  options->output_nclx_profile=&nclx;
  // As in the production writer, the visible gain item precedes the base.
  // A constant full-code gain avoids interpolation/coding uncertainty.
  if(adaptive) {
    heif_image* gain_raw=nullptr;
    check(heif_image_create(size,size,heif_colorspace_monochrome,heif_chroma_monochrome,&gain_raw));
    std::unique_ptr<heif_image,decltype(&heif_image_release)> gain(gain_raw,heif_image_release);
    check(heif_image_add_plane(gain.get(),heif_channel_Y,size,size,8));
    int gain_stride=0;
    auto* gain_plane=heif_image_get_plane(gain.get(),heif_channel_Y,&gain_stride);
    for(unsigned y=0;y<size;++y) std::fill_n(gain_plane+y*gain_stride,size,255);
    heif_image_handle* gain_handle=nullptr;
    check(heif_context_encode_image(context.get(),gain.get(),encoder.get(),nullptr,&gain_handle));
    heif_image_handle_release(gain_handle);
  }
  heif_image_handle* handle_raw=nullptr;
  check(heif_context_encode_image(context.get(),image.get(),encoder.get(),options.get(),&handle_raw));
  std::unique_ptr<heif_image_handle,decltype(&heif_image_handle_release)> handle(handle_raw,heif_image_handle_release);
  check(heif_context_set_primary_image(context.get(),handle.get()));
  check(heif_context_write_to_file(context.get(),path.string().c_str()));
  // Query decoded handles: libheif's encoder-side handle does not provide
  // the reader-side alpha item association used by these inspection APIs.
  std::unique_ptr<heif_context,decltype(&heif_context_free)> verify(heif_context_alloc(),heif_context_free);
  check(heif_context_read_from_file(verify.get(),path.string().c_str(),nullptr));
  heif_image_handle* verified_raw=nullptr;
  check(heif_context_get_primary_image_handle(verify.get(),&verified_raw));
  std::unique_ptr<heif_image_handle,decltype(&heif_image_handle_release)> verified(verified_raw,heif_image_handle_release);
  require(heif_image_handle_has_alpha_channel(verified.get()),"HEIF fixture lost alpha");
  require(bool(heif_image_handle_is_premultiplied_alpha(verified.get()))==premultiplied,
          "HEIF fixture lost premultiplied state");
  verified.reset();
  verify.reset();
  if(adaptive) {
    hyperdr::GainMapMetadata metadata;
    metadata.gain_max={1,1};
    metadata.alternate_headroom={1,1};
    metadata.base_offset={1,4};
    metadata.alternate_offset={1,8};
    const auto bytes=hyperdr::add_tmap_to_two_image_heif(hyperdr::read_binary_file(path),
        hyperdr::serialize_tmap_payload(metadata));
    hyperdr::write_binary_file_atomic(path,bytes,true);
  }
}
double mean(const hyperdr::FloatImage& image) {
  double sum=0;
  for(float value:image.pixels) { require(std::isfinite(value),"nonfinite alpha decode"); sum+=value; }
  return sum/image.pixels.size();
}
}

int main() {
  const auto root=std::filesystem::temp_directory_path()/
      ("hyperdr-alpha-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    std::filesystem::create_directory(root);
    for(bool avif:{false,true}) for(bool premultiplied:{false,true}) {
      const auto path=root/(avif?"fixture.avif":"fixture.heic");
      if(avif) encode_avif(path,premultiplied); else encode_heif(path,premultiplied);
      const auto full=hyperdr::decode_image(path);
      constexpr float expected[]{0,128.0F/255,1,128.0F/255};
      for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
        require(std::abs(full.linear_p3.at(band*8+4,16,c)-expected[band])<0.01F,
                "alpha was ignored or composited in encoded rather than linear light");
      hyperdr::RawDecodeOptions options;
      options.preview_max_edge=8;
      const auto small=hyperdr::decode_image(path,options);
      require(small.linear_p3.width==8 && small.linear_p3.height==8,"alpha fixture was not reduced");
      require(std::abs(mean(full.linear_p3)-mean(small.linear_p3))<1e-5,
              "alpha reduction did not preserve linear composited energy");
      std::cout<<(avif?"AVIF":"HEIF")<<" premultiplied="<<premultiplied<<" mean="<<mean(full.linear_p3)<<'\n';
    }
    const auto adaptive=root/"adaptive.heic";
    encode_heif(adaptive,false,true);
    const auto hdr=hyperdr::decode_image(adaptive);
    constexpr float alpha[]{0,128.0F/255,1,128.0F/255};
    // Reconstruct first: ((white + 1/4)*2 - 1/8)*alpha = 2.375*alpha.
    // Compositing first would leave 0.375 even at alpha=0.
    for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
      require(std::abs(hdr.linear_p3.at(band*8+4,16,c)-2.375F*alpha[band])<0.025F,
              "Adaptive HDR alpha was composited before gain-offset reconstruction");
    hyperdr::RawDecodeOptions base_options;
    base_options.ignore_embedded_gain_map=true;
    const auto base=hyperdr::decode_image(adaptive,base_options);
    for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
      require(std::abs(base.linear_p3.at(band*8+4,16,c)-alpha[band])<0.01F,
              "Adaptive HDR base-only decode did not composite alpha on black");
    std::filesystem::remove_all(root);
    return 0;
  } catch(const std::exception& error) {
    std::cerr<<"alpha decode test failure: "<<error.what()<<'\n';
    std::error_code ignored;
    std::filesystem::remove_all(root,ignored);
    return 1;
  }
}

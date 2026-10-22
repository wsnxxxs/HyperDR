#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/progress.hpp"
#include <avif/avif.h>
#include "heif_test_file.hpp"
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
void encode_heif(const std::filesystem::path& path,bool premultiplied,bool adaptive=false) {
  hyperdr::write_binary_file_atomic(path,heif_test::rgba(premultiplied,adaptive),true);
}
double mean(const hyperdr::FloatImage& image) {
  double sum=0;
  for(float value:image.pixels) { require(std::isfinite(value),"nonfinite alpha decode"); sum+=value; }
  return sum/image.pixels.size();
}
}

int main() try {
  const auto root=hyperdr::test::temporary_directory()/
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
    hyperdr::RawDecodeOptions preview_options;
    preview_options.preview_max_edge=8;
    const auto preview=hyperdr::decode_image(adaptive,preview_options);
    require(preview.authored_sdr && preview.linear_p3.width==8 && preview.linear_p3.height==8 &&
                preview.authored_sdr->width==8 && preview.authored_sdr->height==8 &&
                preview.decode.sensor_width==32 && preview.decode.target_width==32 &&
                preview.decode.decoded_width==8 && !preview.decode.resolution_reduced,
            "Adaptive HDR preview lost aligned renditions or reported a degraded decode");
    require(std::abs(mean(hdr.linear_p3)-mean(preview.linear_p3))<1e-5 &&
                std::abs(mean(*hdr.authored_sdr)-mean(*preview.authored_sdr))<1e-5 &&
                preview.hdr_headroom==hdr.hdr_headroom,
            "Adaptive HDR preview changed authored energy or measured full-size headroom");
    hyperdr::RawDecodeOptions base_options;
    base_options.ignore_embedded_gain_map=true;
    const auto base=hyperdr::decode_image(adaptive,base_options);
    for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
      require(std::abs(base.linear_p3.at(band*8+4,16,c)-alpha[band])<0.01F,
              "Adaptive HDR base-only decode did not composite alpha on black");
    {
      // A budget below the canvas reduces the decode; alpha is still applied at
      // source resolution (straight, premultiplied) or after the gain-map
      // reconstruction (Adaptive), then averaged onto the reduced grid.
      hyperdr::ExecutionScope scope({0, 15ULL*size*size-1});
      constexpr float bands[]{0,128.0F/255,1,128.0F/255};
      for(bool premultiplied:{false,true}) {
        const auto path=root/"reduced.heic";
        encode_heif(path,premultiplied);
        const auto reduced=hyperdr::decode_image(path);
        require(reduced.linear_p3.width==16 && reduced.linear_p3.height==16 &&
                    reduced.decode.resolution_reduced,"alpha fixture was not budget-reduced");
        for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
          require(std::abs(reduced.linear_p3.at(band*4+2,8,c)-bands[band])<0.01F,
                  "budget-reduced HEIF lost its per-pixel alpha");
      }
      const auto path=root/"reduced-adaptive.heic";
      encode_heif(path,false,true);
      const auto reduced=hyperdr::decode_image(path);
      require(reduced.authored_sdr && reduced.linear_p3.width==16 && reduced.authored_sdr->width==16 &&
                  reduced.decode.resolution_reduced,"Adaptive alpha fixture was not budget-reduced");
      for(unsigned band=0;band<4;++band) for(unsigned c=0;c<3;++c)
        require(std::abs(reduced.linear_p3.at(band*4+2,8,c)-2.375F*bands[band])<0.025F,
                "budget-reduced Adaptive HDR alpha was composited before reconstruction");
    }
    std::filesystem::remove_all(root);
    return 0;
  } catch(const std::exception& error) {
    std::cerr<<"alpha decode test failure: "<<error.what()<<'\n';
    std::error_code ignored;
    std::filesystem::remove_all(root,ignored);
    return 1;
  }
} catch (const std::exception& error) {
  std::cerr << "test failure: " << error.what() << '\n';
  return 1;
} catch (...) {
  std::cerr << "unknown test failure\n";
  return 1;
}

#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/model/ncnn_runtime.hpp"
#include "hyperdr/image/frame.hpp"
#include "hyperdr/look/color_lut.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>
#include <ImageIO/ImageIO.h>
#include <CoreGraphics/CoreGraphics.h>

using namespace hyperdr;
namespace {
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
// The embedded ICC profiles carry their creation time (lcms stamps the
// clock), so two encodes a second apart differ there and nowhere else.
std::vector<std::uint8_t> without_icc_dates(std::vector<std::uint8_t> bytes) {
  constexpr std::uint8_t signature[] = {'a', 'c', 's', 'p'};
  for (auto at = bytes.begin() + 36; at + 4 <= bytes.end(); ++at)
    if (std::equal(signature, signature + 4, at)) std::fill(at - 12, at, std::uint8_t{0});
  return bytes;
}
GainMapResult pair(unsigned w, unsigned h, unsigned channels = 1) {
  GainMapResult p;
  p.base_linear = FloatImage(w,h,3);
  std::fill(p.base_linear.pixels.begin(),p.base_linear.pixels.end(),.25F);
  p.gain_map = FloatImage(w,h,channels);
  std::fill(p.gain_map.pixels.begin(),p.gain_map.pixels.end(),.7F);
  p.metadata.base_offset = p.metadata.alternate_offset = {1,64};
  p.metadata.alternate_headroom = {1,1};
  if (channels == 3) {
    p.metadata.flags |= 0x80;
    p.metadata.channels = {{{-1,1},{1,1},{1,1},{1,64},{2,64}},
                           {{-2,1},{2,1},{2,1},{3,64},{4,64}},
                           {{-3,1},{3,1},{3,1},{5,64},{6,64}}};
  }
  return p;
}
void save_floats(const std::filesystem::path& path, const FloatImage& image) {
  std::ofstream out(path, std::ios::binary);
  const std::uint32_t shape[]{image.width,image.height,image.channels};
  out.write(reinterpret_cast<const char*>(shape),sizeof(shape));
  out.write(reinterpret_cast<const char*>(image.pixels.data()),image.pixels.size()*sizeof(float));
  if (!out) throw std::runtime_error("cannot write float reference");
}
void packaging() {
  for (unsigned c : {1,3}) {
    const auto p = pair(64,32,c);
    const auto bytes = encode_gain_map_jpeg(p,{},95);
    verify_gain_map_jpeg(bytes);
    const auto parsed = parse_gain_map_jpeg(bytes);
    require(serialize_tmap_payload(parsed.metadata) == serialize_tmap_payload(p.metadata),
        "per-channel ISO fields changed during JPEG packaging");
    require(without_icc_dates(bytes) == without_icc_dates(encode_gain_map_jpeg(p,{},95)),
        "JPEG output changed on repetition");
    require(parsed.app_segments[1].size() == 1, "gain JPEG has extra APP markers");
    auto bad = p; bad.gain_map = FloatImage(64,32,c == 1 ? 3 : 1);
    bool rejected = false;
    try { (void)encode_gain_map_jpeg(bad,{},95); } catch (const std::invalid_argument&) { rejected = true; }
    require(rejected,"mismatched gain channels accepted");
  }
  for (bool tall : {false,true}) {
    const auto p = pair(tall ? 2 : 65500,tall ? 65500 : 2);
    verify_gain_map_jpeg(encode_gain_map_jpeg(p,{},90));
    verify_sdr_jpeg(encode_sdr_jpeg(p.base_linear,{},90));
    const auto bad = pair(tall ? 2 : 65501,tall ? 65501 : 2);
    for (bool sdr : {false,true}) {
      bool rejected = false;
      try { if (sdr) (void)encode_sdr_jpeg(bad.base_linear,{},90); else (void)encode_gain_map_jpeg(bad,{},90); }
      catch (const ExportDimensionLimit&) { rejected = true; }
      require(rejected,"JPEG dimension limit was not enforced");
    }
  }
  std::cout << "ISO JPEG channel, determinism, 65500/65501 boundary tests passed\n";
}
void fixtures(const std::filesystem::path& root) {
  std::filesystem::create_directories(root);
  for (unsigned c : {1,3}) {
    const auto bytes = encode_gain_map_jpeg(pair(8,8,c),{},95);
    const auto parsed = parse_gain_map_jpeg(bytes);
    write_binary_file_atomic(root/(c==1?"mono.jpg":"rgb.jpg"),bytes,true);
    std::vector<std::uint8_t> primary(bytes.begin(),bytes.begin()+parsed.primary_size);
    for (auto i=parsed.app_segments[0].rbegin();i!=parsed.app_segments[0].rend();++i) {
      if (i->marker==0xe2 && (i->payload[0]=='u' || i->payload[0]=='M'))
        primary.erase(primary.begin()+i->offset,primary.begin()+i->offset+i->payload.size()+4);
    }
    const auto& iso=parsed.app_segments[1][0];
    std::vector<std::uint8_t> gain(bytes.begin()+parsed.gain_offset,bytes.end());
    const auto pos=iso.offset-parsed.gain_offset;
    gain.erase(gain.begin()+pos,gain.begin()+pos+iso.payload.size()+4);
    write_binary_file_atomic(root/"primary.jpg",primary,true);
    write_binary_file_atomic(root/(c==1?"mono-gain.jpg":"rgb-gain.jpg"),gain,true);
  }
}
void large(const std::string& mode, const std::filesystem::path& output) {
  const bool portrait=mode=="portrait";
  const unsigned w=portrait?9504:14000,h=portrait?6336:2000;
  FrameSpec spec; spec.top=spec.right=spec.bottom=spec.left=portrait?.055F:.02F;
  spec.reference=portrait?FrameReference::kShortEdge:FrameReference::kLongEdge;
  spec.caption=portrait?.08F:.06F;
  if(portrait){spec.aspect_width=9;spec.aspect_height=16;}
  const auto layout=layout_frame(spec,w,h);
  GainMapResult p;
  {
    FloatImage photo(w,h,3); std::fill(photo.pixels.begin(),photo.pixels.end(),.25F);
    p.base_linear=frame_image(photo,spec,layout);
  }
  p.gain_map=FloatImage(layout.width,layout.height,1);
  for(unsigned y=0;y<layout.photo.height;++y)
    for(unsigned x=0;x<layout.photo.width;++x)
      p.gain_map.at(layout.photo.x+x,layout.photo.y+y,0)=1;
  p.metadata.base_offset=p.metadata.alternate_offset={1,64};
  p.metadata.gain_max={1,1}; p.metadata.alternate_headroom={1,1};
  auto bytes=encode_gain_map_jpeg(p,{},90);
  p={};
  verify_gain_map_jpeg(bytes);
  const auto parsed=parse_gain_map_jpeg(bytes);
  require(parsed.primary_iso_count==1 && parsed.gain_iso_count==1 && parsed.mpf_count==1,"large file metadata count");
  write_binary_file_atomic(output,bytes,true);
  std::cout << mode << ": " << layout.width << 'x' << layout.height << ", bytes=" << bytes.size() << '\n';
}
// A linear value as a fractional 8-bit sRGB-curve code.
float srgb_code(float linear) {
  const float v = std::max(0.0F, linear);
  return 255.0F * (v <= 0.0031308F ? 12.92F * v : 1.055F * std::pow(v, 1.0F / 2.4F) - 0.055F);
}
// ImageIO's reading of a file: its SDR and HDR decodes as linear extended
// Display P3, and the ISO gain-map codes it finds.
struct ImageIoReading { std::vector<float> sdr, hdr; std::vector<std::uint8_t> gain; bool has_gain = false; };
std::vector<float> draw_linear(CGImageRef image) {
  const auto w = CGImageGetWidth(image), h = CGImageGetHeight(image);
  std::vector<float> pixels(w * h * 4);
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
  CGContextRef context = CGBitmapContextCreate(pixels.data(), w, h, 32, w * 16, space,
      kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Host | kCGBitmapFloatComponents);
  CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
  CGContextRelease(context);
  CGColorSpaceRelease(space);
  return pixels;
}
ImageIoReading read_with_imageio(const std::vector<std::uint8_t>& bytes) {
  ImageIoReading out;
  CFDataRef data = CFDataCreate(nullptr, bytes.data(), static_cast<CFIndex>(bytes.size()));
  CGImageSourceRef source = CGImageSourceCreateWithData(data, nullptr);
  require(source != nullptr, "ImageIO cannot open the gain-map JPEG");
  for (bool hdr : {false, true}) {
    const void* keys[] = {kCGImageSourceDecodeRequest};
    const void* values[] = {kCGImageSourceDecodeToHDR};
    CFDictionaryRef options = hdr ? CFDictionaryCreate(nullptr, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : nullptr;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, options);
    if (options) CFRelease(options);
    require(image != nullptr, "ImageIO cannot decode the gain-map JPEG");
    (hdr ? out.hdr : out.sdr) = draw_linear(image);
    CGImageRelease(image);
  }
  if (CFDictionaryRef info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
          source, 0, kCGImageAuxiliaryDataTypeISOGainMap)) {
    const auto gain = static_cast<CFDataRef>(CFDictionaryGetValue(info, kCGImageAuxiliaryDataInfoData));
    out.has_gain = gain != nullptr;
    if (gain) out.gain.assign(CFDataGetBytePtr(gain), CFDataGetBytePtr(gain) + CFDataGetLength(gain));
    CFRelease(info);
  }
  CFRelease(source);
  CFRelease(data);
  return out;
}
// An explicit zero headroom still writes the requested gain-map JPEG: zero
// gain everywhere, a token AlternateHeadroom above BaseHeadroom so readers
// accept the file, and both readers show the SDR base as the HDR rendition.
void zero_headroom() {
  const auto scratch = std::filesystem::temp_directory_path() /
      ("hyperdr-zero-headroom-" + std::to_string(getpid()));
  std::filesystem::create_directories(scratch);
  constexpr unsigned w = 96, h = 64;
  for (unsigned channels : {1U, 3U}) {
    // Smooth colour ramps: decoders differ in chroma upsampling, which pixel
    // noise would turn into differences that have nothing to do with gain.
    const auto renditions = [&](float hdr_scale, float headroom) {
      PhotoRenditions images;
      images.sdr = FloatImage(w, h, 3);
      images.hdr = FloatImage(w, h, 3);
      for (unsigned y = 0; y < h; ++y)
        for (unsigned x = 0; x < w; ++x) {
          const float rgb[3] = {0.05F + 0.9F * x / (w - 1), 0.05F + 0.9F * y / (h - 1),
                                0.5F - 0.4F * x / (w - 1)};
          for (unsigned c = 0; c < 3; ++c) {
            images.sdr.at(x, y, c) = rgb[c];
            images.hdr.at(x, y, c) = rgb[c] * hdr_scale;
          }
        }
      images.stats.headroom_stops = headroom;
      if (channels == 1) { images.dual_rendition = true; images.authored_gain_channels = 1; }
      return gain_map_from_renditions(std::move(images), GainMapWriterProfile::iso_generic);
    };
    // The HDR rendition would carry gain at any real headroom.
    const auto map = renditions(1.5F, 0);
    // A constant map is stored as one channel shrunk by 16.
    require(map.gain_map.channels == 1 && map.gain_map.width == w / 16 && map.gain_map.height == h / 16,
        "zero-headroom gain map was not shrunk");
    require(std::all_of(map.gain_map.pixels.begin(), map.gain_map.pixels.end(), [](float v) { return v == 0; }),
        "zero headroom left gain in the map");
    require(map.headroom_stops == 0 && map.stats.headroom_stops == 0, "zero headroom reported headroom");
    require(map.metadata.base_headroom.numerator == 0 && map.metadata.alternate_headroom.numerator == 1 &&
            map.metadata.alternate_headroom.denominator == 1U << 23, "zero headroom declared another alternate");
    const auto bytes = encode_gain_map_jpeg(map, {}, 95);
    verify_gain_map_jpeg(bytes);
    require(serialize_tmap_payload(parse_gain_map_jpeg(bytes).metadata) ==
            serialize_tmap_payload(map.metadata), "zero headroom metadata changed in packaging");

    // The reference is the SDR rendition packaged at one stop with zero gain:
    // what each reader shows for a file whose HDR rendition is its base. A
    // reader's HDR decode differs from its own SDR decode by a few codes even
    // then (its chroma upsampling and YCbCr arithmetic differ between the two
    // paths), so the zero-headroom file is compared with that, not with SDR.
    const auto reference = encode_gain_map_jpeg(renditions(1.0F, 1.0F), {}, 95);
    const auto ultrahdr = [&](const std::vector<std::uint8_t>& jpeg, const char* name) {
      const auto file = scratch / name;
      write_binary_file_atomic(file, jpeg, true);
      auto decoded = decode_ultrahdr(file);
      std::filesystem::remove(file);
      return decoded.linear_p3;
    };
    const auto decoded = ultrahdr(bytes, "zero-headroom.jpg");
    const auto expected = ultrahdr(reference, "reference.jpg");
    float worst = 0;
    for (std::size_t i = 0; i < decoded.pixels.size(); ++i)
      worst = std::max(worst, std::abs(srgb_code(decoded.pixels[i]) - srgb_code(expected.pixels[i])));
    require(worst <= 0.5F, "libultrahdr's HDR rendition differs from the SDR base");

    const auto reading = read_with_imageio(bytes);
    require(reading.has_gain, "ImageIO found no ISO gain map");
    require(std::all_of(reading.gain.begin(), reading.gain.end(), [](std::uint8_t v) { return v == 0; }),
        "ImageIO read gain from a zero-headroom map");
    // ImageIO returns its HDR decode as 10-bit pixels encoded for the declared
    // headroom, so the two agree to within one 8-bit code rather than exactly.
    const auto imageio = read_with_imageio(reference);
    require(reading.hdr.size() == imageio.hdr.size(), "ImageIO renditions differ in size");
    worst = 0;
    for (std::size_t i = 0; i < reading.hdr.size(); ++i)
      worst = std::max(worst, std::abs(srgb_code(reading.hdr[i]) - srgb_code(imageio.hdr[i])));
    require(worst <= 1.0F, "ImageIO's HDR rendition differs from the SDR base");
  }
  std::filesystem::remove_all(scratch);
  std::cout << "zero-headroom gain-map JPEG reads as SDR in libultrahdr and ImageIO\n";
}
// Cancelling inside jpeg_finish_compress, where optimize_coding writes most of
// the output, must release the growing output buffer exactly once. Under ASan
// a stale-pointer free there is reported as a double free.
CancelToken* finish_token = nullptr;
int finish_calls = 0, finish_cancel_at = 0;
void finish_observer(bool finishing) {
  if (!finishing) return;
  if (++finish_calls == finish_cancel_at && finish_token) finish_token->request();
}
void cancel_while_finishing() {
  GainMapResult p = pair(1024, 768, 3);
  std::uint32_t seed = 1;
  for (auto& v : p.base_linear.pixels) { seed = seed * 1664525U + 1013904223U; v = (seed >> 8) / 16777216.0F; }
  for (auto& v : p.gain_map.pixels) { seed = seed * 1664525U + 1013904223U; v = (seed >> 8) / 16777216.0F; }
  testing::set_jpeg_progress_observer(finish_observer);
  for (bool gain : {false, true}) {
    const auto encode = [&] {
      return gain ? encode_gain_map_jpeg(p, {}, 95) : encode_sdr_jpeg(p.base_linear, {}, 95);
    };
    finish_calls = 0; finish_cancel_at = 0;
    const auto whole = without_icc_dates(encode());
    const int total = finish_calls;
    require(total > 2, "jpeg_finish_compress reported no progress");
    for (int at : {1, total / 2, total}) {
      CancelToken token;
      finish_token = &token; finish_calls = 0; finish_cancel_at = at;
      bool cancelled = false;
      try { CancelScope scope(&token); (void)encode(); } catch (const Cancelled&) { cancelled = true; }
      finish_token = nullptr;
      require(cancelled, "a cancellation inside jpeg_finish_compress was ignored");
    }
    finish_calls = 0; finish_cancel_at = 0;
    require(without_icc_dates(encode()) == whole, "an encode after a cancelled one changed its bytes");
  }
  testing::set_jpeg_progress_observer(nullptr);
  std::cout << "JPEG cancellation inside jpeg_finish_compress passed\n";
}
void cancel() {
  const auto p=pair(14000,2000);
  CancelToken token;
  std::thread request([&]{std::this_thread::sleep_for(std::chrono::milliseconds(80));token.request();});
  const auto start=std::chrono::steady_clock::now(); bool cancelled=false;
  try {CancelScope scope(&token);(void)encode_gain_map_jpeg(p,{},95);} catch(const Cancelled&){cancelled=true;}
  const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
  request.join();require(cancelled,"encoding ignored cancellation");require(ms<280,"encoding cancellation exceeded 200 ms");
  std::cout << "cancel elapsed=" << ms << " ms (request at 80 ms)\n";
}
void reference(const std::filesystem::path& input, const std::filesystem::path& root, bool model) {
  std::filesystem::create_directories(root);
  auto decoded=decode_image(input,{});
  PhotoRenditions photo;
  if (!model) photo=render_graded_photo(decoded.linear_p3,{},decoded.capture,decoded.describe_input(),RenderTarget::Hdr,{});
  else {
    require(install_embedded_ncnn_runtime(), "native model unavailable");
    GainMapOptions options; options.gain_strength=0; options.look.contrast=1; options.look.vibrance=0; options.look.pop=0;
    auto gain=make_gain_map(decoded.linear_p3,options,decoded.capture,decoded.describe_input());
    auto tensor=make_native_model_input(gain.base_linear);
    NativeModelRequest request; request.model_id="research-cnn-v1"; request.capture=decoded.metadata.capture;
    apply_native_model_gain_map(gain,tensor,infer_native_model(request,tensor));
    photo=render_graded_gain_map(gain,{},true);
    photo.dual_rendition=true;
    photo.authored_gain_channels=gain.gain_map.channels;
    for(unsigned c=0;c<3;++c){auto channel=gain_map_channel(gain.metadata,gain.gain_map.channels==1?0:c);
      photo.authored_gain_map.base_offset[c]=rational_value(channel.base_offset);
      photo.authored_gain_map.alternate_offset[c]=rational_value(channel.alternate_offset);}
  }
  save_floats(root/"render.f32",photo.hdr);
  const auto p=gain_map_from_renditions(std::move(photo),GainMapWriterProfile::iso_generic);
  save_floats(root/"sdr.f32",p.base_linear);
  auto bytes=encode_gain_map_jpeg(p,decoded.metadata,90);
  verify_gain_map_jpeg(bytes);
  write_binary_file_atomic(root/"new.jpg",bytes,true);
  auto ours=decode_image(root/"new.jpg",{});
  save_floats(root/"libuhdr.f32",ours.linear_p3);
  std::cout << "reference headroom=" << p.headroom_stops << " render=" << p.stats.headroom_stops << '\n';
}
}
int main(int argc,char**argv) {
  try {
    const std::string mode=argc>1?argv[1]:"test";
    if(mode=="fixtures" && argc==3) fixtures(argv[2]);
    else if((mode=="panorama"||mode=="portrait")&&argc==3) large(mode,argv[2]);
    else if(mode=="cancel")cancel();
    else if((mode=="reference"||mode=="reference-model")&&argc==4)reference(argv[2],argv[3],mode=="reference-model");
    else { packaging(); zero_headroom(); cancel_while_finishing(); }
    return 0;
  } catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}

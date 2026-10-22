// Diagnostic only. Not linked into either Swift package.
// Usage: jpeg-decode path.jpg. Prints numeric results, never image metadata.
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <jpeglib.h>
#include <lcms2.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <vector>
struct Raster { unsigned w,h,n; std::vector<unsigned char> bytes,icc; };
Raster turbo(const std::vector<unsigned char>& bytes, J_DCT_METHOD dct=JDCT_ISLOW, bool fancy=true) {
 jpeg_decompress_struct d{}; jpeg_error_mgr e{}; d.err=jpeg_std_error(&e); jpeg_create_decompress(&d);
 jpeg_mem_src(&d,bytes.data(),bytes.size()); jpeg_save_markers(&d,JPEG_APP0+2,0xffff); jpeg_read_header(&d,TRUE);
 d.dct_method=dct; d.do_fancy_upsampling=fancy; d.out_color_space=d.num_components==1 ? JCS_GRAYSCALE:JCS_RGB;
 jpeg_start_decompress(&d); Raster r{d.output_width,d.output_height,unsigned(d.output_components)};
 r.bytes.resize(size_t(r.w)*r.h*r.n); while(d.output_scanline<d.output_height) { auto* row=r.bytes.data()+size_t(d.output_scanline)*r.w*r.n; jpeg_read_scanlines(&d,&row,1); }
 unsigned char* icc=nullptr; unsigned size=0;
 if(jpeg_read_icc_profile(&d,&icc,&size)) { r.icc.assign(icc,icc+size); free(icc); }
 jpeg_finish_decompress(&d); jpeg_destroy_decompress(&d); return r;
}
std::vector<unsigned char> encode(const Raster& r, bool gray, bool subsampled) {
 jpeg_compress_struct c{}; jpeg_error_mgr e{}; c.err=jpeg_std_error(&e); jpeg_create_compress(&c);
 unsigned char* bytes=nullptr; unsigned long size=0; jpeg_mem_dest(&c,&bytes,&size);
 c.image_width=r.w;c.image_height=r.h;c.input_components=gray?1:3;c.in_color_space=gray?JCS_GRAYSCALE:JCS_RGB;
 jpeg_set_defaults(&c);jpeg_set_quality(&c,95,TRUE);
 if(!gray) { c.comp_info[0].h_samp_factor=c.comp_info[0].v_samp_factor=subsampled?2:1; }
 jpeg_start_compress(&c,TRUE);
 while(c.next_scanline<c.image_height) { auto* row=const_cast<unsigned char*>(r.bytes.data()+size_t(c.next_scanline)*r.w*(gray?1:3));jpeg_write_scanlines(&c,&row,1); }
 jpeg_finish_compress(&c);std::vector<unsigned char> result(bytes,bytes+size);free(bytes);jpeg_destroy_compress(&c);return result;
}
// Preserve a component's exact quantized DCT blocks and quantization table.
// A grayscale JPEG removes chroma upsampling and YCbCr->RGB from the comparison.
std::vector<unsigned char> coefficientPlane(const std::vector<unsigned char>& bytes, int plane) {
 jpeg_decompress_struct d{};jpeg_error_mgr de{};d.err=jpeg_std_error(&de);jpeg_create_decompress(&d);
 jpeg_mem_src(&d,bytes.data(),bytes.size());jpeg_read_header(&d,TRUE);auto arrays=jpeg_read_coefficients(&d);
 jpeg_compress_struct c{};jpeg_error_mgr ce{};c.err=jpeg_std_error(&ce);jpeg_create_compress(&c);
 unsigned char* output=nullptr;unsigned long size=0;jpeg_mem_dest(&c,&output,&size);
 auto component=d.comp_info[plane];
 c.image_width=(d.image_width*component.h_samp_factor+d.max_h_samp_factor-1)/d.max_h_samp_factor;
 c.image_height=(d.image_height*component.v_samp_factor+d.max_v_samp_factor-1)/d.max_v_samp_factor;
 c.input_components=1;c.in_color_space=JCS_GRAYSCALE;jpeg_set_defaults(&c);
 *c.quant_tbl_ptrs[0]=*d.quant_tbl_ptrs[component.quant_tbl_no];c.quant_tbl_ptrs[0]->sent_table=FALSE;
 jpeg_write_coefficients(&c,arrays+plane);jpeg_finish_compress(&c);
 std::vector<unsigned char> result(output,output+size);free(output);jpeg_destroy_compress(&c);
 jpeg_finish_decompress(&d);jpeg_destroy_decompress(&d);return result;
}
CGImageRef cg(const Raster& r, CGColorSpaceRef space) {
 CFDataRef data=CFDataCreate(nullptr,r.bytes.data(),r.bytes.size());auto provider=CGDataProviderCreateWithCFData(data);
 auto image=CGImageCreate(r.w,r.h,8,r.n*8,r.w*r.n,space,(CGBitmapInfo)kCGImageAlphaNone,provider,nullptr,false,kCGRenderingIntentRelativeColorimetric);
 CGDataProviderRelease(provider);CFRelease(data);return image;
}
CGImageRef appleCG(const std::vector<unsigned char>& bytes) {
 auto source=CGImageSourceCreateWithData((__bridge CFDataRef)[NSData dataWithBytes:bytes.data() length:bytes.size()],nullptr);
 auto image=CGImageSourceCreateImageAtIndex(source,0,nullptr);CFRelease(source);return image;
}
Raster appleCodes(const std::vector<unsigned char>& bytes, bool gray) {
 auto image=appleCG(bytes);auto space=gray?CGColorSpaceCreateDeviceGray():CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
 auto assigned=CGImageCreateCopyWithColorSpace(image,space);
 Raster result{(unsigned)CGImageGetWidth(image),(unsigned)CGImageGetHeight(image),gray?1u:3u};
 std::vector<unsigned char> rgba(size_t(result.w)*result.h*(gray?1:4));
 auto context=CGBitmapContextCreate(rgba.data(),result.w,result.h,8,result.w*(gray?1:4),space,(CGBitmapInfo)(gray?kCGImageAlphaNone:kCGImageAlphaNoneSkipLast));
 CGContextDrawImage(context,CGRectMake(0,0,result.w,result.h),assigned);CGContextRelease(context);
 result.bytes.resize(size_t(result.w)*result.h*result.n);
 for(size_t i=0;i<size_t(result.w)*result.h;i++)for(unsigned c=0;c<result.n;c++)result.bytes[i*result.n+c]=rgba[i*(gray?1:4)+c];
 CGImageRelease(assigned);CGImageRelease(image);CGColorSpaceRelease(space);return result;
}
double transfer(double x) { x=std::clamp(x,0.,1.);return x<=.0031308 ? 12.92*x:1.055*pow(x,1/2.4)-.055; }
void diff(const char* label,const std::vector<double>& a,const std::vector<double>& b,double scale=1) {
 std::vector<double> delta(a.size());double mse=0;for(size_t i=0;i<a.size();i++){delta[i]=abs(a[i]-b[i])*scale;mse+=delta[i]*delta[i];}
 double maximum=*std::max_element(delta.begin(),delta.end());size_t index=size_t(.999*(delta.size()-1));
 std::nth_element(delta.begin(),delta.begin()+index,delta.end());
 std::cout<<label<<" max="<<maximum<<" p999="<<delta[index]<<" rms="<<sqrt(mse/a.size())<<std::endl;
}
std::vector<double> codes(const Raster& r) { return {r.bytes.begin(),r.bytes.end()}; }
std::vector<double> ciImage(CIImage* input, CIContext* context, CGColorSpaceRef output, bool linear=true) {
 unsigned w=input.extent.size.width,h=input.extent.size.height;std::vector<float> data(size_t(w)*h*4);
 [context render:input toBitmap:data.data() rowBytes:w*16 bounds:CGRectMake(0,0,w,h) format:kCIFormatRGBAf colorSpace:output];
 std::vector<double> result(size_t(w)*h*3);for(size_t i=0;i<size_t(w)*h;i++)for(unsigned c=0;c<3;c++)result[i*3+c]=linear?transfer(data[i*4+c]):data[i*4+c];return result;
}
std::vector<double> ci(CGImageRef image,CIContext* context,CGColorSpaceRef output) {
 return ciImage([CIImage imageWithCGImage:image],context,output);
}
std::vector<double> lcms(const Raster& input) {
 auto src=input.icc.empty()?cmsCreate_sRGBProfile():cmsOpenProfileFromMem(input.icc.data(),input.icc.size());
 cmsCIExyY white{.3127,.3290,1};cmsCIExyYTRIPLE primaries{{.680,.320,1},{.265,.690,1},{.150,.060,1}};
 auto curve=cmsBuildGamma(nullptr,1);cmsToneCurve* curves[]{curve,curve,curve};auto dst=cmsCreateRGBProfile(&white,&primaries,curves);cmsFreeToneCurve(curve);
 auto transform=cmsCreateTransform(src,TYPE_RGB_8,dst,TYPE_RGB_FLT,INTENT_RELATIVE_COLORIMETRIC,cmsFLAGS_NOOPTIMIZE|cmsFLAGS_NOCACHE);
 std::vector<float> linear(input.bytes.size());cmsDoTransform(transform,input.bytes.data(),linear.data(),input.w*input.h);
 cmsDeleteTransform(transform);cmsCloseProfile(src);cmsCloseProfile(dst);std::vector<double> result(linear.size());for(size_t i=0;i<linear.size();i++)result[i]=transfer(linear[i]);return result;
}
struct Plane { unsigned w,h; std::vector<double> values; };
double sample(const Plane& p, unsigned x,unsigned y,unsigned width,unsigned height) {
 double u=std::clamp((x+.5)*p.w/width-.5,0.,double(p.w-1)),v=std::clamp((y+.5)*p.h/height-.5,0.,double(p.h-1));
 unsigned x0=floor(u),y0=floor(v),x1=std::min(x0+1,p.w-1),y1=std::min(y0+1,p.h-1);
 double tx=u-x0,ty=v-y0;
 return std::lerp(std::lerp(p.values[y0*p.w+x0],p.values[y0*p.w+x1],tx),
                  std::lerp(p.values[y1*p.w+x0],p.values[y1*p.w+x1],tx),ty);
}
std::vector<double> planarRGB(const std::vector<Plane>& p,unsigned w,unsigned h) {
 std::vector<double> result(size_t(w)*h*3);
 for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
  double Y=sample(p[0],x,y,w,h),cb=sample(p[1],x,y,w,h)-128,cr=sample(p[2],x,y,w,h)-128;
  size_t i=(size_t(y)*w+x)*3;
  result[i]=std::clamp(Y+1.402*cr,0.,255.);
  result[i+1]=std::clamp(Y-.344136286*cb-.714136286*cr,0.,255.);
  result[i+2]=std::clamp(Y+1.772*cb,0.,255.);
 }
 return result;
}
int main(int argc,char** argv) { @autoreleasepool {
 if(argc!=2)return 2;NSData* data=[NSData dataWithContentsOfFile:@(argv[1])];if(!data)return 3;
 std::vector<unsigned char> bytes((unsigned char*)data.bytes,(unsigned char*)data.bytes+data.length);
 auto decoded=turbo(bytes);auto apple=appleCodes(bytes,false);
 diff("original_decode_codes_8bit",codes(decoded),codes(apple));
 diff("original_no_fancy_vs_apple_8bit",codes(turbo(bytes,JDCT_ISLOW,false)),codes(apple));
 for(auto method:{JDCT_IFAST,JDCT_FLOAT})diff(method==JDCT_IFAST?"ifast_vs_apple_8bit":"float_vs_apple_8bit",codes(turbo(bytes,method)),codes(apple));
 auto output=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
 auto context=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf),kCIContextWorkingColorSpace:(__bridge id)output}];
 auto profile=decoded.icc.empty()?CGColorSpaceCreateWithName(kCGColorSpaceSRGB):CGColorSpaceCreateWithICCData((__bridge CFDataRef)[NSData dataWithBytes:decoded.icc.data() length:decoded.icc.size()]);
 auto turboImage=cg(decoded,profile);auto appleImage=appleCG(bytes);
 auto old=lcms(decoded),sameRGB=ci(turboImage,context,output),system=ci(appleImage,context,output);
 diff("same_RGB_ICC_10bit",old,sameRGB,1023);diff("CGImage_decode_10bit",sameRGB,system,1023);diff("CGImage_total_10bit",old,system,1023);
 auto direct=[CIImage imageWithData:data];
 auto directRGB=ciImage(direct,context,output);
 diff("CI_direct_total_10bit",old,directRGB,1023);
 diff("CI_direct_decode_10bit",sameRGB,directRGB,1023);
 auto noColor=[CIContext contextWithOptions:@{kCIContextWorkingFormat:@(kCIFormatRGBAf),kCIContextWorkingColorSpace:[NSNull null]}];
 auto untagged=[CIImage imageWithData:data options:@{kCIImageColorSpace:[NSNull null]}];
 auto native=ciImage(untagged,noColor,nullptr,false);
 for(double& x:native)x=std::clamp(x,0.,1.)*255;
 diff("CI_unmanaged_fancy_decode_8bit",codes(decoded),native);
 diff("CI_unmanaged_nearest_decode_8bit",codes(turbo(bytes,JDCT_ISLOW,false)),native);
 std::vector<Plane> turboPlanes,systemPlanes;
 for(int plane=0;plane<3;plane++) {
  auto component=coefficientPlane(bytes,plane);
  diff(plane==0?"original_Y_IDCT_8bit":plane==1?"original_Cb_IDCT_8bit":"original_Cr_IDCT_8bit",
       codes(turbo(component)),codes(appleCodes(component,true)));
  auto t=turbo(component);turboPlanes.push_back({t.w,t.h,codes(t)});
  auto monoImage=[CIImage imageWithData:[NSData dataWithBytes:component.data() length:component.size()] options:@{kCIImageColorSpace:[NSNull null]}];
  auto monoFloat=ciImage(monoImage,noColor,nullptr,false);
  Plane source{t.w,t.h};source.values.resize(size_t(t.w)*t.h);
  for(size_t i=0;i<source.values.size();i++)source.values[i]=monoFloat[i*3]*255;
  diff(plane==0?"CI_Y_IDCT_float_8bit":plane==1?"CI_Cb_IDCT_float_8bit":"CI_Cr_IDCT_float_8bit",codes(t),source.values);
  systemPlanes.push_back(std::move(source));
 }
 diff("system_IDCT_bilinear_matrix_vs_CI_8bit",planarRGB(systemPlanes,decoded.w,decoded.h),native);
 diff("turbo_IDCT_bilinear_matrix_vs_CI_8bit",planarRGB(turboPlanes,decoded.w,decoded.h),native);
 // Fresh 4:4:4 and grayscale JPEGs isolate IDCT/YCbCr rounding from chroma interpolation.
 auto rgb=decoded;rgb.icc.clear();auto full=encode(rgb,false,false);
 diff("synthetic_444_8bit",codes(turbo(full)),codes(appleCodes(full,false)));
 auto fullInput=[CIImage imageWithData:[NSData dataWithBytes:full.data() length:full.size()] options:@{kCIImageColorSpace:[NSNull null]}];
 auto native444=ciImage(fullInput,noColor,nullptr,false);for(double& x:native444)x=std::clamp(x,0.,1.)*255;
 diff("CI_unmanaged_444_decode_8bit",codes(turbo(full)),native444);
 Raster gray{rgb.w,rgb.h,1};gray.bytes.resize(size_t(rgb.w)*rgb.h);for(size_t i=0;i<gray.bytes.size();i++)gray.bytes[i]=rgb.bytes[i*3];
 auto mono=encode(gray,true,false);diff("synthetic_gray_IDCT_8bit",codes(turbo(mono)),codes(appleCodes(mono,true)));
 // Lossless grayscale -> 4:4:4 -> 4:2:0 controls, keeping the same Y structure.
 for(size_t i=0;i<gray.bytes.size();i++)rgb.bytes[i*3]=rgb.bytes[i*3+1]=rgb.bytes[i*3+2]=gray.bytes[i];
 auto neutral=encode(rgb,false,true);diff("neutral_420_8bit",codes(turbo(neutral)),codes(appleCodes(neutral,false)));
 CGImageRelease(turboImage);CGImageRelease(appleImage);CGColorSpaceRelease(profile);CGColorSpaceRelease(output);
} }

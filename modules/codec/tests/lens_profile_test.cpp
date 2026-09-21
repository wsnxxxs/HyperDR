#include "hyperdr/codec/lens_profile.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
hyperdr::FloatImage rotate(const hyperdr::FloatImage& src, int flip) {
  hyperdr::FloatImage out((flip&4) ? src.height : src.width,
                         (flip&4) ? src.width : src.height, src.channels);
  for (unsigned y=0;y<out.height;++y) for (unsigned x=0;x<out.width;++x) {
    unsigned sx=x, sy=y;
    if (flip&4) std::swap(sx,sy);
    if (flip&1) sx=src.width-1-sx;
    if (flip&2) sy=src.height-1-sy;
    for(unsigned c=0;c<src.channels;++c) out.at(x,y,c)=src.at(sx,sy,c);
  }
  return out;
}
}
int main(int argc, char** argv) {
  const auto path=std::filesystem::temp_directory_path()/
      ("hyperdr-lcp-"+std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())+".lcp");
  try {
    {
      std::ofstream out(path);
      out << R"(<rdf:RDF><rdf:Description stCamera:CameraRawProfile="True" stCamera:SensorFormatFactor="1">
        <rdf:li><rdf:Description stCamera:FocalLength="35" stCamera:ApertureValue="2">
        <stCamera:PerspectiveModel stCamera:Version="2" stCamera:RadialDistortParam1="-0.1">
        <stCamera:VignetteModel stCamera:VignetteModelParam1="-0.2"/>
        </stCamera:PerspectiveModel></rdf:Description></rdf:li>
        <rdf:li><stCamera:FocalLength>70</stCamera:FocalLength><stCamera:ApertureValue>2</stCamera:ApertureValue>
        <stCamera:PerspectiveModel><rdf:Description><stCamera:Version>2</stCamera:Version>
        <stCamera:RadialDistortParam1>-0.3</stCamera:RadialDistortParam1>
        </rdf:Description></stCamera:PerspectiveModel></rdf:li>
        </rdf:Description></rdf:RDF>)";
    }
    auto profile=hyperdr::read_lens_profile(path);
    require(profile.calibrations.size()==2,"Both XML serializations must parse");
    require(profile.calibrations[0].distortion.fx==1 && profile.calibrations[1].distortion.fx==2,
            "Missing focal scales use inherited sensor factor");
    hyperdr::FloatImage ramp(100,60,3);
    for(unsigned y=0;y<ramp.height;++y) for(unsigned x=0;x<ramp.width;++x)
      for(unsigned c=0;c<3;++c) ramp.at(x,y,c)=static_cast<float>(x+2*y+c);
    profile.calibrations[0].vignette.reset();
    auto corrected=ramp;
    (void)hyperdr::apply_lens_profile(corrected,profile,std::sqrt(35.0*70.0),2,0);
    // At the geometric-mean focal length k1=-.2, fx=fy=1.5.
    const double x=(20.-50)/150, y=(20.-30)/150, radial=1-.2*(x*x+y*y);
    const double expected=(x*radial*150+50)+2*(y*radial*150+30);
    require(std::abs(corrected.at(20,20,0)-expected)<1e-4,"Log focal interpolation and inverse image sampling");
    // An asymmetric optical centre and tangential term must rotate with sensor.
    profile.calibrations.resize(1);
    profile.calibrations[0].distortion.cx=.43;
    profile.calibrations[0].distortion.cy=.57;
    profile.calibrations[0].distortion.tangential={.005,-.004};
    corrected=ramp;
    (void)hyperdr::apply_lens_profile(corrected,profile,35,2,0);
    for(int flip=0;flip<8;++flip) {
      auto oriented=rotate(ramp,flip);
      (void)hyperdr::apply_lens_profile(oriented,profile,35,2,flip);
      const auto expected_image=rotate(corrected,flip);
      for(std::size_t i=0;i<oriented.pixels.size();++i)
        require(std::abs(oriented.pixels[i]-expected_image.pixels[i])<1e-4,"Correction must commute with sensor orientation");
    }
    hyperdr::LensCalibration c;
    c.focal_length=35; c.aperture_value=2;
    // A vignette-only profile must not perturb geometry, even with focal
    // scales/centres whose identity mapping would accumulate roundoff.
    c.distortion.fx=.731; c.distortion.fy=.819;
    c.distortion.cx=.437; c.distortion.cy=.563;
    profile.calibrations={c};
    corrected=ramp;
    (void)hyperdr::apply_lens_profile(corrected,profile,35,2,0);
    require(corrected.pixels==ramp.pixels,"Identity distortion must preserve every sample exactly");
    c.distortion=hyperdr::LensModel{};
    c.vignette=hyperdr::LensModel{}; c.vignette->radial[0]=-.4;
    auto d=c; d.aperture_value=4; d.vignette->radial[0]=-.2;
    profile.calibrations={c,d};
    hyperdr::FloatImage flat(100,60,3);
    std::fill(flat.pixels.begin(),flat.pixels.end(),2.f);
    const auto kind=hyperdr::apply_lens_profile(flat,profile,35,std::sqrt(8.),0);
    require(kind=="distortion,vignette","Applied correction types");
    require(std::abs(flat.at(20,30,0)-2/(1-.3*.09))<1e-5,"Vignette gain and aperture interpolation preserve headroom");
    profile.calibrations={c}; profile.calibrations[0].vignette.reset();
    profile.calibrations[0].distortion.radial[0]=.5;
    std::fill(flat.pixels.begin(),flat.pixels.end(),2.f);
    (void)hyperdr::apply_lens_profile(flat,profile,35,2,0);
    for(float value:flat.pixels) require(std::abs(value-2)<1e-5,"Automatic fill must leave no black borders");
    // Compare against an analytic band-limited image at the exact inverse
    // distortion coordinates. A sharper kernel must improve reconstruction,
    // not merely increase gradients or introduce ringing around edges.
    hyperdr::FloatImage detail(256,160,3);
    const auto signal=[](double x,double y) { return .5+.2*std::sin(x*.8)+.2*std::cos(y*.7); };
    for(unsigned y=0;y<detail.height;++y) for(unsigned x=0;x<detail.width;++x)
      for(unsigned channel=0;channel<3;++channel) detail.at(x,y,channel)=static_cast<float>(signal(x,y));
    const auto original=detail;
    profile.calibrations[0].distortion.radial[0]=-.2;
    (void)hyperdr::apply_lens_profile(detail,profile,35,2,0);
    double cubic_error=0,linear_error=0;
    for(unsigned y=4;y+4<detail.height;++y) for(unsigned x=4;x+4<detail.width;++x) {
      const double nx=(double(x)-128)/256,ny=(double(y)-80)/256;
      const double scale=1-.2*(nx*nx+ny*ny);
      const double sx=nx*scale*256+128,sy=ny*scale*256+80;
      const unsigned ix=static_cast<unsigned>(sx),iy=static_cast<unsigned>(sy);
      const double linear=std::lerp(std::lerp(double(original.at(ix,iy,0)),double(original.at(ix+1,iy,0)),sx-ix),
          std::lerp(double(original.at(ix,iy+1,0)),double(original.at(ix+1,iy+1,0)),sx-ix),sy-iy);
      const double expected=signal(sx,sy);
      cubic_error+=std::pow(detail.at(x,y,0)-expected,2);
      linear_error+=std::pow(linear-expected,2);
    }
    std::cout << "Cubic/bilinear detail MSE ratio: " << cubic_error/linear_error << '\n';
    require(cubic_error<linear_error*.2,"Lens resampling must retain band-limited detail");
    // A step with scene headroom and negative matrix values must not ring
    // outside its source range or be clipped to the display's [0,1] range.
    for(unsigned y=0;y<detail.height;++y) for(unsigned x=0;x<detail.width;++x)
      for(unsigned channel=0;channel<3;++channel) detail.at(x,y,channel)=x<128?-.2F:4.F;
    (void)hyperdr::apply_lens_profile(detail,profile,35,2,0);
    for(float value:detail.pixels) require(value>=-.2F && value<=4.F,"Cubic ringing must respect scene range");
    { std::ofstream out(path); out << "<root><FisheyeModel/></root>"; }
    bool rejected=false;
    try { (void)hyperdr::read_lens_profile(path); } catch(const std::invalid_argument&) { rejected=true; }
    require(rejected,"Unsupported fisheye must fail");
    {
      std::ofstream out(path);
      out << R"(<root CameraRawProfile="True" SensorFormatFactor="1">
        <item FocalLength="35" ApertureValue="4" FocusDistance="1">
          <PerspectiveModel Version="2" RadialDistortParam1="-0.4" ResidualMeanError="0.1">
            <VignetteModel VignetteModelParam1="-0.4" ResidualMeanError="0.01"/>
          </PerspectiveModel>
        </item>
        <item FocalLength="35" ApertureValue="4" FocusDistance="10000">
          <PerspectiveModel Version="2" RadialDistortParam1="-0.1" ResidualMeanError="0.01">
            <VignetteModel VignetteModelParam1="-0.1" ResidualMeanError="0.1"/>
          </PerspectiveModel>
        </item></root>)";
    }
    auto duplicates=hyperdr::read_lens_profile(path);
    auto ordered=ramp, reversed=ramp;
    (void)hyperdr::apply_lens_profile(ordered,duplicates,35,2,0);
    std::reverse(duplicates.calibrations.begin(),duplicates.calibrations.end());
    (void)hyperdr::apply_lens_profile(reversed,duplicates,35,2,0);
    require(ordered.pixels==reversed.pixels,"LCP record order must not choose the calibration");
    // Geometry and vignetting have independent calibration residuals.
    auto best=duplicates;
    best.calibrations[0].vignette=best.calibrations[1].vignette;
    best.calibrations.resize(1);
    auto expected_best=ramp;
    (void)hyperdr::apply_lens_profile(expected_best,best,35,2,0);
    require(ordered.pixels==expected_best.pixels,"Choose the lowest residual for each correction independently");
    for(int i=1;i<argc;++i) {
      const auto p=hyperdr::read_lens_profile(argv[i]);
      hyperdr::FloatImage image(300,200,3);
      std::fill(image.pixels.begin(),image.pixels.end(),1.f);
      const auto& sample=p.calibrations.front();
      const auto applied=hyperdr::apply_lens_profile(image,p,sample.focal_length,std::exp2(sample.aperture_value/2),0);
      for(float v:image.pixels) require(std::isfinite(v) && v>0,"Real LCP must produce finite filled pixels");
      std::cout << p.calibrations.size() << " calibrations: " << applied << '\n';
    }
    std::filesystem::remove(path);
    std::cout << "Lens profile tests passed\n";
    return 0;
  } catch(const std::exception& e) {
    std::filesystem::remove(path);
    std::cerr << e.what() << '\n'; return 1;
  }
}

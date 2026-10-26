#pragma once

#include <lcms2.h>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hyperdr::codec {

inline std::vector<std::uint8_t> srgb_profile() {
  const auto profile = cmsCreate_sRGBProfile();
  if (!profile) throw std::runtime_error("cannot create sRGB profile");
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(profile, nullptr, &size) || !size) {
    cmsCloseProfile(profile);
    throw std::runtime_error("cannot size sRGB profile");
  }
  std::vector<std::uint8_t> data(size);
  const auto saved = cmsSaveProfileToMem(profile, data.data(), &size);
  cmsCloseProfile(profile);
  if (!saved) throw std::runtime_error("cannot serialize sRGB profile");
  data.resize(size);
  return data;
}

inline std::vector<std::uint8_t> display_p3_profile(bool linear = false) {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{{0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}};
  // Little CMS type 4 is the IEC 61966-2-1 form, parameters {g, a, b, c, d}:
  // Y = (aX + b)^g for X >= d, and Y = cX below it. The slope c used to sit in
  // the unused sixth slot with 0 in its place, which zeroed the linear toe: any
  // ICC-honouring reader decoded every base code under 10/255 as black, and a
  // gain map cannot bring back a shadow that multiplies zero.
  double parameters[]{2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045};
  cmsToneCurve* curve = linear ? cmsBuildGamma(nullptr, 1.0)
                               : cmsBuildParametricToneCurve(nullptr, 4, parameters);
  if (!curve) throw std::runtime_error("cannot build Display P3 tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  cmsHPROFILE profile = cmsCreateRGBProfile(&white, &primaries, curves);
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot create Display P3 ICC profile");
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(profile, nullptr, &size) || size == 0) { cmsCloseProfile(profile); throw std::runtime_error("cannot size ICC profile"); }
  std::vector<std::uint8_t> data(size);
  if (!cmsSaveProfileToMem(profile, data.data(), &size)) { cmsCloseProfile(profile); throw std::runtime_error("cannot serialize ICC profile"); }
  cmsCloseProfile(profile);
  data.resize(size);
  return data;
}

// A matrix/TRC profile with a linear curve for sRGB, Display P3 or Rec.2020
// primaries (D65). Float files use it: their samples are linear light, with
// SDR white at 1.0 and HDR highlights above it.
inline std::vector<std::uint8_t> linear_rgb_profile(double red_x, double red_y, double green_x,
                                                    double green_y, double blue_x, double blue_y,
                                                    const char* description) {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{{red_x, red_y, 1.0}, {green_x, green_y, 1.0}, {blue_x, blue_y, 1.0}};
  cmsToneCurve* curve = cmsBuildGamma(nullptr, 1.0);
  if (!curve) throw std::runtime_error("cannot build a linear tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  cmsHPROFILE profile = cmsCreateRGBProfile(&white, &primaries, curves);
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot create a linear ICC profile");
  cmsMLU* text = cmsMLUalloc(nullptr, 1);
  if (text && cmsMLUsetASCII(text, "en", "US", description))
    cmsWriteTag(profile, cmsSigProfileDescriptionTag, text);
  if (text) cmsMLUfree(text);
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(profile, nullptr, &size) || size == 0) { cmsCloseProfile(profile); throw std::runtime_error("cannot size ICC profile"); }
  std::vector<std::uint8_t> data(size);
  if (!cmsSaveProfileToMem(profile, data.data(), &size)) { cmsCloseProfile(profile); throw std::runtime_error("cannot serialize ICC profile"); }
  cmsCloseProfile(profile);
  data.resize(size);
  return data;
}

}  // namespace hyperdr::codec

#pragma once

#include <lcms2.h>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hyperdr::codec {

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

}  // namespace hyperdr::codec

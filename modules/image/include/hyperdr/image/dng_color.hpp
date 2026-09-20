#pragma once

// The DNG specification's camera colour model ("Mapping Camera Color Space to
// CIE XYZ Space", DNG 1.6) for three-colour cameras, computed as the Adobe DNG
// SDK computes it (dng_color_spec): the two ColorMatrix and CameraCalibration
// pairs are interpolated in inverse correlated colour temperature at the scene
// white, which is itself found from the camera neutral by iteration, and a
// ForwardMatrix, when the file has one, takes over from the inverted
// ColorMatrix. LibRaw applies only the D65 ColorMatrix, whatever the light
// was. A profile's HueSatMap, LookTable and ToneCurve are a look, not
// calibration, and are not part of this. Pure maths, so the core tests can
// hold it to the specification.

#include <array>
#include <cstdint>
#include <optional>

namespace hyperdr {

using Matrix3d = std::array<std::array<double, 3>, 3>;

struct DngCalibration {
  // EXIF LightSource code of CalibrationIlluminantN; 0 when absent.
  std::uint16_t illuminant{0};
  // ColorMatrixN: XYZ to reference camera values.
  std::optional<Matrix3d> color_matrix;
  // ForwardMatrixN: white-balanced reference camera values to XYZ D50.
  std::optional<Matrix3d> forward_matrix;
  // CameraCalibrationN: reference camera to this camera; identity when absent.
  std::optional<Matrix3d> camera_calibration;
};

struct DngColorProfile {
  std::array<DngCalibration, 2> calibrations;
  std::array<double, 3> analog_balance{1.0, 1.0, 1.0};
};

struct DngColorTransform {
  Matrix3d camera_to_p3;
  double illuminant_weight{1.0};
  double temperature{5000.0};
};
// Same white-balanced input convention as dng_camera_to_linear_p3. Weight is
// for calibration 1 as stored, including profiles with reversed illuminants.
[[nodiscard]] std::optional<DngColorTransform> dng_camera_color_transform(
    const DngColorProfile& profile, const std::array<double, 3>& neutral);

// The temperature, in kelvin, the DNG SDK interpolates a calibration at for an
// EXIF LightSource code: 2850 for standard light A, 5000 for D50, 6500 for
// D65, the middle of a fluorescent class's range, and so on. Profiles are
// made and checked against these round values rather than each illuminant's
// exact correlated colour temperature. 0 for an unknown code or "other light
// source", which leaves a profile with its first calibration only.
[[nodiscard]] double dng_illuminant_temperature(std::uint16_t light_source);

// Correlated colour temperature of an xy chromaticity by Robertson's method,
// on the CIE 1960 UCS isotemperature lines from 10 to 600 mired.
[[nodiscard]] double correlated_color_temperature(double x, double y);

// The matrix taking white-balanced camera RGB -- raw values divided by
// `neutral`, the camera's raw response to the scene white (AsShotNeutral, or
// the reciprocal of the white-balance multipliers applied) -- to linear
// Display P3 (D65), with that white at luminance 1. Empty where the SDK would
// reject the profile (no ColorMatrix1, a singular colour matrix, a forward
// matrix that does not take equal camera values to within 0.01 of D50) or the
// neutral or AnalogBalance is not positive.
[[nodiscard]] std::optional<Matrix3d> dng_camera_to_linear_p3(
    const DngColorProfile& profile, const std::array<double, 3>& neutral);

}  // namespace hyperdr

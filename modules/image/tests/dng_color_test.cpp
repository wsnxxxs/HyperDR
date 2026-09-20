#include "hyperdr/image/dng_color.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

using hyperdr::DngColorProfile;
using hyperdr::Matrix3d;
using hyperdr::correlated_color_temperature;
using hyperdr::dng_camera_to_linear_p3;
using hyperdr::dng_illuminant_temperature;

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

double max_difference(const Matrix3d& a, const Matrix3d& b) {
  double out = 0.0;
  for (std::size_t i = 0; i < 3; ++i) {
    for (std::size_t j = 0; j < 3; ++j) out = std::max(out, std::abs(a[i][j] - b[i][j]));
  }
  return out;
}

Matrix3d scaled(Matrix3d m, double factor) {
  for (auto& row : m) {
    for (auto& value : row) value *= factor;
  }
  return m;
}

Matrix3d required(const std::optional<Matrix3d>& matrix, const std::string& what) {
  require(matrix.has_value(), what + " must give a matrix");
  for (const auto& row : *matrix) {
    require(std::abs(row[0] + row[1] + row[2] - 1.0) < 1.0e-5,
            what + " must take the neutral to P3 white");
  }
  return *matrix;
}

constexpr Matrix3d kIdentity{{{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}};

// XYZ to linear Display P3: a camera whose raw channels are linear P3.
constexpr Matrix3d kP3Camera{{{2.4934969, -0.9313836, -0.4027108},
                              {-0.8294890, 1.7626641, 0.0236247},
                              {0.0358458, -0.0761724, 0.9568845}}};
// That camera's white-balanced channels to XYZ D50: its primaries, Bradford
// adapted from D65.
constexpr Matrix3d kP3CameraForward{{{0.5151464482, 0.2920099744, 0.1571392618},
                                     {0.2412003276, 0.6922225263, 0.0665771348},
                                     {-0.0010501254, 0.0418782823, 0.7842764960}}};
// Its raw response to a white under standard light A (xy 0.4476, 0.4074).
constexpr std::array<double, 3> kP3CameraTungsten{1.9364439932, 1.0, 0.3533424614};

// A Ricoh GR IV DNG: ColorMatrix1 under standard light A, ColorMatrix2 under
// D65, and the file's AsShotNeutral, a white near 4600 K.
constexpr Matrix3d kRicohA{{{0.698959, -0.287201, -0.031876},
                            {-0.380997, 0.997040, 0.446777},
                            {-0.011490, 0.036133, 0.737518}}};
constexpr Matrix3d kRicohD65{{{0.642670, -0.148453, -0.081421},
                              {-0.461395, 1.272781, 0.206543},
                              {-0.067871, 0.151535, 0.603012}}};
constexpr std::array<double, 3> kRicohNeutral{0.4136, 1.0, 0.5614};

// EXIF LightSource codes.
constexpr std::uint16_t kUnknown = 0;
constexpr std::uint16_t kStandardLightA = 17;
constexpr std::uint16_t kD65 = 21;

DngColorProfile single(std::uint16_t illuminant, const Matrix3d& color_matrix) {
  DngColorProfile profile;
  profile.calibrations[0].illuminant = illuminant;
  profile.calibrations[0].color_matrix = color_matrix;
  return profile;
}

DngColorProfile dual(std::uint16_t first_illuminant, const Matrix3d& first,
                     std::uint16_t second_illuminant, const Matrix3d& second) {
  auto profile = single(first_illuminant, first);
  profile.calibrations[1].illuminant = second_illuminant;
  profile.calibrations[1].color_matrix = second;
  return profile;
}

void test_correlated_color_temperature() {
  // The CIE illuminants' own correlated colour temperatures.
  require(std::abs(correlated_color_temperature(0.3127, 0.3290) - 6504.0) < 2.0, "D65 is 6504 K");
  require(std::abs(correlated_color_temperature(0.4476, 0.4074) - 2856.0) < 3.0,
          "standard light A is 2856 K");
  require(std::abs(correlated_color_temperature(0.3457, 0.3585) - 5003.0) < 3.0, "D50 is 5003 K");
  require(std::abs(correlated_color_temperature(0.2990, 0.3149) - 7504.0) < 4.0, "D75 is 7504 K");
  // A point on the Planckian locus at 325 mired. The published Robertson table
  // misprints its u as 0.24702, which would read this white as 3056 K.
  const double u = 0.24792;
  const double v = 0.34655;
  const double d = 2.0 * u - 8.0 * v + 4.0;
  require(std::abs(correlated_color_temperature(3.0 * u / d, 2.0 * v / d) - 1.0e6 / 325.0) < 0.5,
          "the locus at 325 mired must read as 3077 K");
  // Along a path near the locus from bluish to reddish whites the temperature
  // only falls.
  double previous = 0.0;
  for (int step = 0; step <= 90; ++step) {
    const double t = static_cast<double>(step) / 90.0;
    const double x = 0.28 + t * (0.52 - 0.28);
    const double y = 0.29 + t * (0.415 - 0.29) - 0.05 * t * (1.0 - t);
    const double temperature = correlated_color_temperature(x, y);
    require(previous == 0.0 || temperature < previous,
            "colour temperature must fall from bluish to reddish whites");
    previous = temperature;
  }
}

void test_illuminant_temperatures() {
  // The DNG SDK's values, which profiles are built against.
  require(dng_illuminant_temperature(kStandardLightA) == 2850.0 &&
              dng_illuminant_temperature(kD65) == 6500.0 &&
              dng_illuminant_temperature(23) == 5000.0 && dng_illuminant_temperature(20) == 5500.0 &&
              dng_illuminant_temperature(14) == 4150.0 && dng_illuminant_temperature(24) == 3200.0,
          "calibration illuminants must use the DNG SDK temperatures");
  require(dng_illuminant_temperature(kUnknown) == 0.0 && dng_illuminant_temperature(255) == 0.0,
          "unknown and other light sources have no temperature");
}

void test_color_matrix_adapts_with_bradford() {
  const auto profile = single(kD65, kP3Camera);
  // Under D65 the P3 camera's neutral is equal and its channels are P3.
  const auto daylight =
      required(dng_camera_to_linear_p3(profile, {1.0, 1.0, 1.0}), "a D65 white");
  require(max_difference(daylight, kIdentity) < 1.0e-5, "a P3 camera under D65 must be P3");
  // Under standard light A the white-balanced values are adapted to D65 with
  // Bradford (values from an independent port of the SDK's colour spec), not
  // just divided per channel, which would leave the identity.
  const auto tungsten = required(dng_camera_to_linear_p3(profile, kP3CameraTungsten), "a tungsten white");
  const Matrix3d expected{{{1.2995790956, -0.2679272209, -0.0316518747},
                           {0.0168442522, 0.9983108130, -0.0151550652},
                           {0.0119722970, 0.0160927025, 0.9719350005}}};
  require(max_difference(tungsten, expected) < 2.0e-5,
          "a colour matrix must adapt a tungsten white to D65 with Bradford");
}

void test_forward_matrix_balances_in_camera_space() {
  // A ForwardMatrix is defined on white-balanced reference camera values, so
  // the balance happens in the camera's own space: for the P3 camera, whose
  // ForwardMatrix is its own primaries, white-balanced values come through
  // unchanged under any light.
  auto profile = single(kD65, kP3Camera);
  profile.calibrations[0].forward_matrix = kP3CameraForward;
  const auto tungsten = required(dng_camera_to_linear_p3(profile, kP3CameraTungsten),
                                 "a forward matrix under standard light A");
  require(max_difference(tungsten, kIdentity) < 1.0e-5,
          "a forward matrix must white balance in camera space");
  // Row sums within 0.01 of D50 are scaled onto it exactly (a white that
  // missed D50 would tint every colour); further off, the SDK refuses the
  // profile, and so does this.
  auto nearly = kP3CameraForward;
  for (auto& value : nearly[0]) value *= 0.995;
  for (auto& value : nearly[2]) value *= 1.008;
  profile.calibrations[0].forward_matrix = nearly;
  require(max_difference(required(dng_camera_to_linear_p3(profile, kP3CameraTungsten),
                                  "a forward matrix slightly off D50"),
                         kIdentity) < 1.0e-5,
          "a forward matrix must be normalised to D50");
  auto missing = kP3CameraForward;
  for (auto& value : missing[2]) value *= 1.02;
  profile.calibrations[0].forward_matrix = missing;
  require(!dng_camera_to_linear_p3(profile, kP3CameraTungsten),
          "a forward matrix that misses D50 must be refused");
}

void test_dual_illuminant_interpolation() {
  const auto profile = dual(kStandardLightA, kRicohA, kD65, kRicohD65);
  // At the as-shot white, near 4600 K, a third of the way from the D65
  // calibration to standard light A in inverse temperature (values from an
  // independent port of the SDK's colour spec).
  const auto as_shot = required(dng_camera_to_linear_p3(profile, kRicohNeutral), "the as-shot white");
  const Matrix3d expected{{{1.3602788941, -0.2818658161, -0.0784130696},
                           {-0.1265696843, 1.5046563045, -0.3780866215},
                           {0.0220360932, -0.2989782308, 1.2769421249}}};
  require(max_difference(as_shot, expected) < 2.0e-5,
          "two calibrations must be interpolated at the scene white");
  // A Pixel XL HDR+ DNG lists D65 first and carries a CameraCalibration per
  // calibration; the SDK interpolates each calibration's product
  // CameraCalibration * ColorMatrix.
  auto pixel = dual(kD65,
                    Matrix3d{{{0.7692, -0.2068, -0.091}, {-0.5955, 1.431, 0.1737}, {-0.2481, 0.3391, 0.5955}}},
                    kStandardLightA,
                    Matrix3d{{{1.06, -0.3072, -0.2765}, {-0.553, 1.6283, -0.1152}, {-0.0614, 0.1997, 0.6145}}});
  pixel.calibrations[0].camera_calibration = Matrix3d{{{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0078}}};
  pixel.calibrations[1].camera_calibration = Matrix3d{{{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0156}}};
  const Matrix3d pixel_expected{{{1.2532708323, -0.2368901682, -0.0163806640},
                                 {-0.0912130941, 1.2422129449, -0.1509998508},
                                 {0.1239282780, -0.4972506997, 1.3733224220}}};
  require(max_difference(required(dng_camera_to_linear_p3(pixel, {0.4567, 1.0, 0.6142}), "a Pixel XL DNG"),
                         pixel_expected) < 2.0e-5,
          "camera calibrations must be applied per calibration");
  const auto d65_only = required(dng_camera_to_linear_p3(single(kD65, kRicohD65), kRicohNeutral),
                                 "the D65 calibration alone");
  require(max_difference(as_shot, d65_only) > 0.05,
          "a 4600 K white must not use the D65 calibration alone");

  // At or above 6500 K only the D65 calibration applies, at or below 2850 K
  // only standard light A's.
  const std::array<double, 3> daylight{0.3528233229, 1.0, 0.7021843715};  // D65
  require(max_difference(required(dng_camera_to_linear_p3(profile, daylight), "a D65 white"),
                         required(dng_camera_to_linear_p3(single(kD65, kRicohD65), daylight),
                                  "a D65 white, one calibration")) < 1.0e-6,
          "a D65 white must use the D65 calibration alone");
  const std::array<double, 3> candle{0.7143794661, 1.0, 0.3405822204};  // about 2600 K
  require(max_difference(
              required(dng_camera_to_linear_p3(profile, candle), "a 2600 K white"),
              required(dng_camera_to_linear_p3(single(kStandardLightA, kRicohA), candle),
                       "a 2600 K white, one calibration")) < 1.0e-6,
          "a white below 2850 K must use the standard light A calibration alone");

  // The order the file lists its calibrations in does not matter.
  require(max_difference(as_shot,
                         required(dng_camera_to_linear_p3(dual(kD65, kRicohD65, kStandardLightA, kRicohA),
                                                          kRicohNeutral),
                                  "reversed calibrations")) < 1.0e-12,
          "calibrations must be ordered by temperature");
  // An unknown illuminant, or two calibrations under the same one, leaves the
  // first calibration alone.
  const auto first_only = required(
      dng_camera_to_linear_p3(single(kStandardLightA, kRicohA), kRicohNeutral), "the first calibration");
  require(max_difference(first_only,
                         required(dng_camera_to_linear_p3(dual(kStandardLightA, kRicohA, kUnknown, kRicohD65),
                                                          kRicohNeutral),
                                  "an unknown second illuminant")) < 1.0e-12,
          "an unknown illuminant must not be interpolated");
  require(max_difference(first_only,
                         required(dng_camera_to_linear_p3(
                                      dual(kStandardLightA, kRicohA, kStandardLightA, kRicohD65),
                                      kRicohNeutral),
                                  "two calibrations under one illuminant")) < 1.0e-12,
          "calibrations under one illuminant must not be interpolated");
}

void test_color_matrix_scale() {
  // A ColorMatrix more than 1% off scale is normalised before it is
  // interpolated, so scaling it changes nothing.
  const double pcs_x = 0.3457 / 0.3585;
  const double pcs_z = (1.0 - 0.3457 - 0.3585) / 0.3585;
  double largest = 0.0;
  for (const auto& row : kRicohD65) largest = std::max(largest, row[0] * pcs_x + row[1] + row[2] * pcs_z);
  const auto normalised = scaled(kRicohD65, 1.0 / largest);
  const auto reference = required(
      dng_camera_to_linear_p3(dual(kStandardLightA, kRicohA, kD65, normalised), kRicohNeutral),
      "a normalised colour matrix");
  const auto off_scale = required(
      dng_camera_to_linear_p3(dual(kStandardLightA, kRicohA, kD65, scaled(normalised, 1.2)), kRicohNeutral),
      "a colour matrix 20% off scale");
  require(max_difference(reference, off_scale) < 1.0e-9, "an off-scale colour matrix must be normalised");
}

void test_raw_channel_gains_cancel() {
  // AnalogBalance and a diagonal CameraCalibration only rescale raw channels,
  // and the neutral is measured in the rescaled channels, so white-balanced
  // values come out the same.
  const auto reference = required(
      dng_camera_to_linear_p3(dual(kStandardLightA, kRicohA, kD65, kRicohD65), kRicohNeutral), "no gains");
  const std::array<double, 3> gains{1.3, 1.0, 0.8};
  std::array<double, 3> rescaled{};
  for (std::size_t c = 0; c < 3; ++c) rescaled[c] = kRicohNeutral[c] * gains[c];

  auto balanced = dual(kStandardLightA, kRicohA, kD65, kRicohD65);
  balanced.analog_balance = gains;
  require(max_difference(reference, required(dng_camera_to_linear_p3(balanced, rescaled), "analog balance")) <
              1.0e-9,
          "AnalogBalance must cancel against the neutral");

  auto calibrated = dual(kStandardLightA, kRicohA, kD65, kRicohD65);
  const Matrix3d calibration{{{gains[0], 0.0, 0.0}, {0.0, gains[1], 0.0}, {0.0, 0.0, gains[2]}}};
  calibrated.calibrations[0].camera_calibration = calibration;
  calibrated.calibrations[1].camera_calibration = calibration;
  require(max_difference(reference,
                         required(dng_camera_to_linear_p3(calibrated, rescaled), "camera calibration")) < 1.0e-9,
          "a diagonal CameraCalibration must cancel against the neutral");

  auto forward = single(kD65, kP3Camera);
  forward.calibrations[0].forward_matrix = kP3CameraForward;
  forward.analog_balance = gains;
  std::array<double, 3> tungsten{};
  for (std::size_t c = 0; c < 3; ++c) tungsten[c] = kP3CameraTungsten[c] * gains[c];
  require(max_difference(kIdentity, required(dng_camera_to_linear_p3(forward, tungsten),
                                             "a forward matrix with analog balance")) < 1.0e-5,
          "AnalogBalance must cancel on the forward-matrix path");
}

void test_rejections() {
  DngColorProfile second_only;
  second_only.calibrations[1].illuminant = kD65;
  second_only.calibrations[1].color_matrix = kRicohD65;
  require(!dng_camera_to_linear_p3(second_only, kRicohNeutral), "ColorMatrix1 is required");
  require(!dng_camera_to_linear_p3(single(kD65, Matrix3d{}), kRicohNeutral),
          "a singular colour matrix must be refused");
  require(!dng_camera_to_linear_p3(dual(kStandardLightA, kRicohA, kD65, Matrix3d{}), kRicohNeutral),
          "a singular second colour matrix must be refused");
  const auto profile = dual(kStandardLightA, kRicohA, kD65, kRicohD65);
  const double nan = std::numeric_limits<double>::quiet_NaN();
  for (const auto& neutral : {std::array<double, 3>{0.0, 1.0, 0.5}, std::array<double, 3>{0.4, -1.0, 0.5},
                              std::array<double, 3>{0.4, 1.0, nan}}) {
    require(!dng_camera_to_linear_p3(profile, neutral), "a neutral must be positive and finite");
  }
  auto unbalanced = profile;
  unbalanced.analog_balance = {1.0, 0.0, 1.0};
  require(!dng_camera_to_linear_p3(unbalanced, kRicohNeutral), "AnalogBalance must be positive");
}

}  // namespace

int main() {
  try {
    test_correlated_color_temperature();
    test_illuminant_temperatures();
    test_color_matrix_adapts_with_bradford();
    test_forward_matrix_balances_in_camera_space();
    test_dual_illuminant_interpolation();
    test_color_matrix_scale();
    test_raw_channel_gains_cancel();
    test_rejections();
    std::cout << "DNG colour tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}

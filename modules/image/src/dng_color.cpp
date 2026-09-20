#include "hyperdr/image/dng_color.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <utility>

namespace hyperdr {
namespace {

using Vector3d = std::array<double, 3>;
using Xy = std::array<double, 2>;

// The profile connection space white, D50 as the DNG SDK writes it, and the D65
// white of the Display P3 matrices this project uses.
constexpr Xy kD50{0.3457, 0.3585};
constexpr Xy kD65{0.3127, 0.3290};

Matrix3d identity() { return {{{1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}}}; }

Matrix3d diagonal(const Vector3d& v) {
  return {{{v[0], 0.0, 0.0}, {0.0, v[1], 0.0}, {0.0, 0.0, v[2]}}};
}

Matrix3d multiply(const Matrix3d& a, const Matrix3d& b) {
  Matrix3d out{};
  for (std::size_t i = 0; i < 3; ++i) {
    for (std::size_t j = 0; j < 3; ++j) {
      for (std::size_t k = 0; k < 3; ++k) out[i][j] += a[i][k] * b[k][j];
    }
  }
  return out;
}

Vector3d multiply(const Matrix3d& m, const Vector3d& v) {
  return {m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
          m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
          m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2]};
}

Matrix3d scaled(Matrix3d m, double factor) {
  for (auto& row : m) {
    for (auto& value : row) value *= factor;
  }
  return m;
}

// weight * a + (1 - weight) * b
Matrix3d mix(const Matrix3d& a, const Matrix3d& b, double weight) {
  Matrix3d out{};
  for (std::size_t i = 0; i < 3; ++i) {
    for (std::size_t j = 0; j < 3; ++j) out[i][j] = weight * a[i][j] + (1.0 - weight) * b[i][j];
  }
  return out;
}

std::optional<Matrix3d> invert(const Matrix3d& m) {
  const double c00 = m[1][1] * m[2][2] - m[1][2] * m[2][1];
  const double c01 = m[1][2] * m[2][0] - m[1][0] * m[2][2];
  const double c02 = m[1][0] * m[2][1] - m[1][1] * m[2][0];
  const double determinant = m[0][0] * c00 + m[0][1] * c01 + m[0][2] * c02;
  if (!(std::abs(determinant) > 1.0e-12) || !std::isfinite(determinant)) return std::nullopt;
  const double inverse = 1.0 / determinant;
  return Matrix3d{{{c00 * inverse, (m[0][2] * m[2][1] - m[0][1] * m[2][2]) * inverse,
                    (m[0][1] * m[1][2] - m[0][2] * m[1][1]) * inverse},
                   {c01 * inverse, (m[0][0] * m[2][2] - m[0][2] * m[2][0]) * inverse,
                    (m[0][2] * m[1][0] - m[0][0] * m[1][2]) * inverse},
                   {c02 * inverse, (m[0][1] * m[2][0] - m[0][0] * m[2][1]) * inverse,
                    (m[0][0] * m[1][1] - m[0][1] * m[1][0]) * inverse}}};
}

// XYZ at Y = 1, with x and y held inside the range of real colours, as the SDK
// holds them, so an extreme white cannot divide by zero.
Vector3d xy_to_xyz(Xy xy) {
  xy[0] = std::clamp(xy[0], 0.000001, 0.999999);
  xy[1] = std::clamp(xy[1], 0.000001, 0.999999);
  if (xy[0] + xy[1] > 0.999999) {
    const double scale = 0.999999 / (xy[0] + xy[1]);
    xy[0] *= scale;
    xy[1] *= scale;
  }
  return {xy[0] / xy[1], 1.0, (1.0 - xy[0] - xy[1]) / xy[1]};
}

Xy xyz_to_xy(const Vector3d& xyz) {
  const double sum = xyz[0] + xyz[1] + xyz[2];
  if (!(sum > 0.0) || !std::isfinite(sum)) return kD50;
  return {xyz[0] / sum, xyz[1] / sum};
}

// Bradford chromatic adaptation from one white to another, its cone gains held
// to [0.1, 10] so a wild white cannot blow the matrix up.
Matrix3d bradford(const Xy& from, const Xy& to) {
  const Matrix3d cone{{{0.8951, 0.2664, -0.1614}, {-0.7502, 1.7135, 0.0367},
                       {0.0389, -0.0685, 1.0296}}};
  const auto source = multiply(cone, xy_to_xyz(from));
  const auto target = multiply(cone, xy_to_xyz(to));
  Vector3d gain{};
  for (std::size_t i = 0; i < 3; ++i) {
    const double s = std::max(source[i], 0.0);
    const double t = std::max(target[i], 0.0);
    gain[i] = std::clamp(s > 0.0 ? t / s : 10.0, 0.1, 10.0);
  }
  return multiply(multiply(*invert(cone), diagonal(gain)), cone);
}

// Robertson's isotemperature lines: reciprocal megakelvin, the Planckian locus
// in CIE 1960 u, v, and the slope of the isotemperature line there. Recomputed
// from the CIE 1931 observer and Planck's law, the u and v agree to 2e-4 and
// the slopes to 0.1%. The u at 325 mired is 0.24792; the published table, and
// the DNG SDK's copy of it, print 0.24702, which moves whites between 2860 and
// 3330 K by up to 27 K.
struct IsotemperatureLine {
  double mired, u, v, slope;
};
constexpr std::array<IsotemperatureLine, 31> kIsotemperatureLines{{
    {0.0, 0.18006, 0.26352, -0.24341},   {10.0, 0.18066, 0.26589, -0.25479},
    {20.0, 0.18133, 0.26846, -0.26876},  {30.0, 0.18208, 0.27119, -0.28539},
    {40.0, 0.18293, 0.27407, -0.30470},  {50.0, 0.18388, 0.27709, -0.32675},
    {60.0, 0.18494, 0.28021, -0.35156},  {70.0, 0.18611, 0.28342, -0.37915},
    {80.0, 0.18740, 0.28668, -0.40955},  {90.0, 0.18880, 0.28997, -0.44278},
    {100.0, 0.19032, 0.29326, -0.47888}, {125.0, 0.19462, 0.30141, -0.58204},
    {150.0, 0.19962, 0.30921, -0.70471}, {175.0, 0.20525, 0.31647, -0.84901},
    {200.0, 0.21142, 0.32312, -1.0182},  {225.0, 0.21807, 0.32909, -1.2168},
    {250.0, 0.22511, 0.33439, -1.4512},  {275.0, 0.23247, 0.33904, -1.7298},
    {300.0, 0.24010, 0.34308, -2.0637},  {325.0, 0.24792, 0.34655, -2.4681},
    {350.0, 0.25591, 0.34951, -2.9641},  {375.0, 0.26400, 0.35200, -3.5814},
    {400.0, 0.27218, 0.35407, -4.3633},  {425.0, 0.28039, 0.35577, -5.3762},
    {450.0, 0.28863, 0.35714, -6.7262},  {475.0, 0.29685, 0.35823, -8.5955},
    {500.0, 0.30505, 0.35907, -11.324},  {525.0, 0.31320, 0.35968, -15.628},
    {550.0, 0.32129, 0.36011, -23.325},  {575.0, 0.32931, 0.36038, -40.770},
    {600.0, 0.33724, 0.36051, -116.45},
}};

// The profile as the DNG SDK's colour spec holds it: each ColorMatrix with
// AnalogBalance and CameraCalibration folded in, each ForwardMatrix scaled to
// take equal camera values exactly to the PCS white, and the two calibrations
// in temperature order. A profile without a second usable calibration uses its
// first at every temperature. (The SDK also rounds the matrices it reads to
// four decimals, for its fingerprints; that is left out.)
struct ColorSpec {
  double temperature1{5000.0};
  double temperature2{5000.0};
  std::array<Matrix3d, 2> color_matrix{};
  std::array<Matrix3d, 2> camera_calibration{};
  std::array<std::optional<Matrix3d>, 2> forward_matrix;
};

std::optional<ColorSpec> color_spec(const DngColorProfile& profile) {
  const auto& first = profile.calibrations[0];
  const auto& second = profile.calibrations[1];
  // What the SDK accepts: ColorMatrix1 present, the colour matrices
  // invertible, and forward matrices that already take equal camera values to
  // within 0.01 of the PCS white.
  if (!first.color_matrix) return std::nullopt;
  const auto pcs = xy_to_xyz(kD50);
  for (const auto& calibration : profile.calibrations) {
    if (calibration.color_matrix && !invert(*calibration.color_matrix)) return std::nullopt;
    if (calibration.forward_matrix) {
      const auto xyz = multiply(*calibration.forward_matrix, Vector3d{1.0, 1.0, 1.0});
      for (std::size_t i = 0; i < 3; ++i) {
        if (!(std::abs(xyz[i] - pcs[i]) <= 0.01)) return std::nullopt;
      }
    }
  }
  for (const double gain : profile.analog_balance) {
    if (!(gain > 0.0) || !std::isfinite(gain)) return std::nullopt;
  }

  const auto color_matrix = [&](const DngCalibration& calibration) {
    // A matrix more than 1% off is scaled so the PCS white reaches 1 in the
    // largest camera channel. Only interpolation between two matrices sees
    // the scale.
    auto matrix = *calibration.color_matrix;
    const auto camera = multiply(matrix, pcs);
    const double largest = std::max({camera[0], camera[1], camera[2]});
    if (largest > 0.0 && (largest < 0.99 || largest > 1.01)) matrix = scaled(matrix, 1.0 / largest);
    return multiply(multiply(diagonal(profile.analog_balance),
                             calibration.camera_calibration.value_or(identity())),
                    matrix);
  };
  const auto forward_matrix = [&](const DngCalibration& calibration) -> std::optional<Matrix3d> {
    if (!calibration.forward_matrix) return std::nullopt;
    auto matrix = *calibration.forward_matrix;
    for (std::size_t i = 0; i < 3; ++i) {
      const double sum = matrix[i][0] + matrix[i][1] + matrix[i][2];
      for (auto& value : matrix[i]) value *= pcs[i] / sum;
    }
    return matrix;
  };

  ColorSpec spec;
  spec.color_matrix[0] = color_matrix(first);
  spec.camera_calibration[0] = first.camera_calibration.value_or(identity());
  spec.forward_matrix[0] = forward_matrix(first);
  const double temperature1 = dng_illuminant_temperature(first.illuminant);
  const double temperature2 = dng_illuminant_temperature(second.illuminant);
  if (!second.color_matrix || temperature1 <= 0.0 || temperature2 <= 0.0 ||
      temperature1 == temperature2) {
    spec.color_matrix[1] = spec.color_matrix[0];
    spec.camera_calibration[1] = spec.camera_calibration[0];
    spec.forward_matrix[1] = spec.forward_matrix[0];
    return spec;
  }
  spec.temperature1 = temperature1;
  spec.temperature2 = temperature2;
  spec.color_matrix[1] = color_matrix(second);
  spec.camera_calibration[1] = second.camera_calibration.value_or(identity());
  spec.forward_matrix[1] = forward_matrix(second);
  if (temperature1 > temperature2) {
    std::swap(spec.temperature1, spec.temperature2);
    std::swap(spec.color_matrix[0], spec.color_matrix[1]);
    std::swap(spec.camera_calibration[0], spec.camera_calibration[1]);
    std::swap(spec.forward_matrix[0], spec.forward_matrix[1]);
  }
  return spec;
}

struct AtWhite {
  Matrix3d color_matrix;  // AnalogBalance * CameraCalibration * ColorMatrix
  Matrix3d camera_calibration;
  std::optional<Matrix3d> forward_matrix;
};

// The calibrations interpolated in inverse temperature at a white: all of the
// first at or below its temperature, all of the second at or above its own.
AtWhite at_white(const ColorSpec& spec, const Xy& white) {
  const double temperature = correlated_color_temperature(white[0], white[1]);
  double weight = 0.0;
  if (temperature <= spec.temperature1) {
    weight = 1.0;
  } else if (temperature < spec.temperature2) {
    weight = (1.0 / temperature - 1.0 / spec.temperature2) /
             (1.0 / spec.temperature1 - 1.0 / spec.temperature2);
  }
  const auto pick = [weight](const Matrix3d& first, const Matrix3d& second) {
    return weight >= 1.0 ? first : (weight <= 0.0 ? second : mix(first, second, weight));
  };
  AtWhite out;
  out.color_matrix = pick(spec.color_matrix[0], spec.color_matrix[1]);
  out.camera_calibration = pick(spec.camera_calibration[0], spec.camera_calibration[1]);
  const auto& first = spec.forward_matrix[0];
  const auto& second = spec.forward_matrix[1];
  out.forward_matrix = first && second ? std::optional<Matrix3d>(pick(*first, *second))
                                       : (first ? first : second);
  return out;
}

}  // namespace

double dng_illuminant_temperature(std::uint16_t light_source) {
  switch (light_source) {
    case 17:  // Standard light A
    case 3:   // Tungsten (incandescent)
      return 2850.0;
    case 24: return 3200.0;  // ISO studio tungsten
    case 23: return 5000.0;  // D50
    case 20:  // D55
    case 1:   // Daylight
    case 9:   // Fine weather
    case 4:   // Flash
    case 18:  // Standard light B
      return 5500.0;
    case 21:  // D65
    case 19:  // Standard light C
    case 10:  // Cloudy weather
      return 6500.0;
    case 22:  // D75
    case 11:  // Shade
      return 7500.0;
    case 12: return (5700.0 + 7100.0) * 0.5;  // Daylight fluorescent
    case 13: return (4600.0 + 5500.0) * 0.5;  // Day white fluorescent
    case 14:  // Cool white fluorescent
    case 2:   // Fluorescent
      return (3800.0 + 4500.0) * 0.5;
    case 15: return (3250.0 + 3800.0) * 0.5;  // White fluorescent
    case 16: return (2600.0 + 3250.0) * 0.5;  // Warm white fluorescent
    default: return 0.0;
  }
}

double correlated_color_temperature(double x, double y) {
  const double denominator = 1.5 - x + 6.0 * y;
  if (!(std::abs(denominator) > 1.0e-12)) return 0.0;
  const double u = 2.0 * x / denominator;
  const double v = 3.0 * y / denominator;
  double last_distance = 0.0;
  for (std::size_t index = 1; index < kIsotemperatureLines.size(); ++index) {
    const auto& line = kIsotemperatureLines[index];
    const double length = std::sqrt(1.0 + line.slope * line.slope);
    const double du = 1.0 / length;
    const double dv = line.slope / length;
    // Signed distance from this isotemperature line; the point lies between
    // the previous line and this one once the sign turns.
    double distance = -(u - line.u) * dv + (v - line.v) * du;
    if (distance <= 0.0 || index == kIsotemperatureLines.size() - 1) {
      distance = -std::min(distance, 0.0);
      const double fraction = index == 1 ? 0.0 : distance / (last_distance + distance);
      const double mired = kIsotemperatureLines[index - 1].mired * fraction +
                           line.mired * (1.0 - fraction);
      return 1.0e6 / mired;
    }
    last_distance = distance;
  }
  return 0.0;
}

std::optional<Matrix3d> dng_camera_to_linear_p3(const DngColorProfile& profile,
                                                const std::array<double, 3>& neutral) {
  for (const double value : neutral) {
    if (!(value > 0.0) || !std::isfinite(value)) return std::nullopt;
  }
  const auto spec = color_spec(profile);
  if (!spec) return std::nullopt;

  // The scene white: the xy whose colour matrix, interpolated at that white,
  // takes it to the camera neutral. Found by fixed-point iteration from D50;
  // an oscillation that has not settled after 30 passes is averaged.
  Xy white = kD50;
  constexpr int kPasses = 30;
  for (int pass = 0; pass < kPasses; ++pass) {
    const auto inverse = invert(at_white(*spec, white).color_matrix);
    if (!inverse) return std::nullopt;
    Xy next = xyz_to_xy(multiply(*inverse, neutral));
    if (std::abs(next[0] - white[0]) + std::abs(next[1] - white[1]) < 1.0e-7) {
      white = next;
      break;
    }
    if (pass == kPasses - 1) next = {(white[0] + next[0]) * 0.5, (white[1] + next[1]) * 0.5};
    white = next;
  }

  const auto matrices = at_white(*spec, white);
  Matrix3d camera_to_d50{};
  if (matrices.forward_matrix) {
    // ForwardMatrix maps white-balanced reference camera values to D50: the
    // camera white is taken back through AnalogBalance * CameraCalibration and
    // divided out.
    auto camera_white = multiply(matrices.color_matrix, xy_to_xyz(white));
    const double largest = std::max({camera_white[0], camera_white[1], camera_white[2]});
    if (!(largest > 0.0) || !std::isfinite(largest)) return std::nullopt;
    for (auto& value : camera_white) value = std::clamp(value / largest, 0.001, 1.0);
    const auto to_reference = invert(
        multiply(diagonal(profile.analog_balance), matrices.camera_calibration));
    if (!to_reference) return std::nullopt;
    const auto reference_white = multiply(*to_reference, camera_white);
    for (const double value : reference_white) {
      if (!(value > 0.0) || !std::isfinite(value)) return std::nullopt;
    }
    const Vector3d balance{1.0 / reference_white[0], 1.0 / reference_white[1],
                           1.0 / reference_white[2]};
    camera_to_d50 =
        multiply(multiply(*matrices.forward_matrix, diagonal(balance)), *to_reference);
  } else {
    // D50 to camera through the scene white, inverted.
    const auto inverse = invert(multiply(matrices.color_matrix, bradford(kD50, white)));
    if (!inverse) return std::nullopt;
    camera_to_d50 = *inverse;
  }

  // White-balanced camera RGB is raw divided by the neutral, so the neutral
  // goes back in before the raw-referred matrix; the result is adapted to D65
  // and scaled so the white lands at luminance 1.
  auto camera_to_d65 = multiply(bradford(kD50, kD65), multiply(camera_to_d50, diagonal(neutral)));
  const double white_luminance =
      camera_to_d65[1][0] + camera_to_d65[1][1] + camera_to_d65[1][2];
  if (!(white_luminance > 0.0) || !std::isfinite(white_luminance)) return std::nullopt;
  camera_to_d65 = scaled(camera_to_d65, 1.0 / white_luminance);
  const Matrix3d xyz_to_p3{{{2.4934969, -0.9313836, -0.4027108},
                            {-0.8294890, 1.7626641, 0.0236247},
                            {0.0358458, -0.0761724, 0.9568845}}};
  return multiply(xyz_to_p3, camera_to_d65);
}

}  // namespace hyperdr

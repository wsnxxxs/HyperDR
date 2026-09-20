#include "hyperdr/image/fidelity.hpp"

#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

struct Ictcp {
  float i, ct, cp;
};

// BT.2100 ICtCp from linear P3 relative to diffuse white. The LMS matrix is
// linear, so it is applied to relative values and pq_oetf does the 203 cd/m²
// scaling it already owns.
Ictcp to_ictcp(const std::array<float, 3>& p3) {
  const auto rgb = p3_to_rec2020(p3[0], p3[1], p3[2]);
  const float r = std::max(0.0F, rgb[0]);
  const float g = std::max(0.0F, rgb[1]);
  const float b = std::max(0.0F, rgb[2]);
  const float l = pq_oetf((1688.0F * r + 2146.0F * g + 262.0F * b) / 4096.0F);
  const float m = pq_oetf((683.0F * r + 2951.0F * g + 462.0F * b) / 4096.0F);
  const float s = pq_oetf((99.0F * r + 309.0F * g + 3688.0F * b) / 4096.0F);
  return {0.5F * l + 0.5F * m, (6610.0F * l - 13613.0F * m + 7003.0F * s) / 4096.0F,
          (17933.0F * l - 17390.0F * m - 543.0F * s) / 4096.0F};
}

float distance(const Ictcp& a, const Ictcp& b) {
  const float di = a.i - b.i;
  const float dt = 0.5F * (a.ct - b.ct);
  const float dp = a.cp - b.cp;
  return 720.0F * std::sqrt(di * di + dt * dt + dp * dp);
}

std::array<float, 3> pq_rec2020(const std::array<float, 3>& p3) {
  const auto rgb = p3_to_rec2020(p3[0], p3[1], p3[2]);
  return {pq_oetf(std::max(0.0F, rgb[0])), pq_oetf(std::max(0.0F, rgb[1])),
          pq_oetf(std::max(0.0F, rgb[2]))};
}

// Percentiles come from a histogram rather than a sort: a 60 MP comparison
// would otherwise hold a quarter of a gigabyte of distances just to rank them.
// 0.01 ΔE resolution is finer than any threshold anyone reads a ΔE ITP at, and
// the exact maximum is tracked separately.
constexpr float kBinWidth = 0.01F;
constexpr std::size_t kBins = 4096;
// Rows are grouped so each worker owns one histogram rather than one per row.
constexpr std::uint32_t kRowsPerBlock = 32;

struct Block {
  std::vector<std::uint32_t> histogram = std::vector<std::uint32_t>(kBins, 0);
  double delta_sum{0.0};
  double squared_pq_error{0.0};
  double reference_luminance{0.0};
  double candidate_luminance{0.0};
  float reference_peak{0.0F};
  float candidate_peak{0.0F};
  float delta_max{0.0F};
  std::uint64_t above_1{0}, above_2{0}, above_5{0};
  std::array<double, 3> band_sum{};
  std::array<std::uint64_t, 3> band_count{};
};

std::array<float, 3> pixel(const FloatImage& image, std::size_t index) {
  const auto finite = [](float value) { return std::isfinite(value) ? value : 0.0F; };
  return {finite(image.pixels[index]), finite(image.pixels[index + 1]),
          finite(image.pixels[index + 2])};
}

}  // namespace

float delta_e_itp(const std::array<float, 3>& reference,
                  const std::array<float, 3>& candidate) {
  return distance(to_ictcp(reference), to_ictcp(candidate));
}

HdrFidelity measure_hdr_fidelity(const FloatImage& reference,
                                 const FloatImage& candidate) {
  reference.require_consistent("fidelity reference");
  candidate.require_consistent("fidelity candidate");
  if (reference.channels != 3 || candidate.channels != 3) {
    throw std::invalid_argument("fidelity comparison requires RGB images");
  }
  if (reference.width != candidate.width || reference.height != candidate.height) {
    throw std::invalid_argument(
        "fidelity comparison requires images of identical dimensions: reference " +
        std::to_string(reference.width) + "x" + std::to_string(reference.height) +
        ", candidate " + std::to_string(candidate.width) + "x" +
        std::to_string(candidate.height));
  }

  const std::uint32_t block_count =
      (reference.height + kRowsPerBlock - 1U) / kRowsPerBlock;
  std::vector<Block> blocks(block_count);
  parallel_for_rows(block_count, [&](const std::uint32_t block_index) {
    auto& block = blocks[block_index];
    const std::uint32_t y0 = block_index * kRowsPerBlock;
    const std::uint32_t y1 = std::min(reference.height, y0 + kRowsPerBlock);
    for (std::uint32_t y = y0; y < y1; ++y) {
      for (std::uint32_t x = 0; x < reference.width; ++x) {
        const auto index = (static_cast<std::size_t>(y) * reference.width + x) * 3U;
        const auto a = pixel(reference, index);
        const auto b = pixel(candidate, index);
        const float delta = delta_e_itp(a, b);
        block.delta_sum += delta;
        block.delta_max = std::max(block.delta_max, delta);
        block.above_1 += delta > 1.0F ? 1U : 0U;
        block.above_2 += delta > 2.0F ? 1U : 0U;
        block.above_5 += delta > 5.0F ? 1U : 0U;
        ++block.histogram[std::min<std::size_t>(
            static_cast<std::size_t>(delta / kBinWidth), kBins - 1U)];

        const auto pa = pq_rec2020(a);
        const auto pb = pq_rec2020(b);
        for (unsigned c = 0; c < 3; ++c) {
          const double error = static_cast<double>(pa[c]) - pb[c];
          block.squared_pq_error += error * error;
        }

        const float ya = p3_luminance(a[0], a[1], a[2]);
        const float yb = p3_luminance(b[0], b[1], b[2]);
        block.reference_luminance += ya;
        block.candidate_luminance += yb;
        block.reference_peak = std::max(block.reference_peak, ya);
        block.candidate_peak = std::max(block.candidate_peak, yb);
        const std::size_t band = ya < HdrFidelity::kBandEdges[0]   ? 0U
                                 : ya <= HdrFidelity::kBandEdges[1] ? 1U
                                                                    : 2U;
        block.band_sum[band] += delta;
        ++block.band_count[band];
      }
    }
  });

  HdrFidelity result;
  result.pixels = static_cast<std::uint64_t>(reference.width) * reference.height;
  std::vector<std::uint64_t> histogram(kBins, 0);
  double delta_sum = 0.0, squared_pq_error = 0.0;
  double reference_luminance = 0.0, candidate_luminance = 0.0;
  std::uint64_t above_1 = 0, above_2 = 0, above_5 = 0;
  for (const auto& block : blocks) {
    for (std::size_t bin = 0; bin < kBins; ++bin) histogram[bin] += block.histogram[bin];
    delta_sum += block.delta_sum;
    squared_pq_error += block.squared_pq_error;
    reference_luminance += block.reference_luminance;
    candidate_luminance += block.candidate_luminance;
    result.reference_peak = std::max(result.reference_peak, block.reference_peak);
    result.candidate_peak = std::max(result.candidate_peak, block.candidate_peak);
    result.delta_e_itp_max = std::max(result.delta_e_itp_max, block.delta_max);
    above_1 += block.above_1;
    above_2 += block.above_2;
    above_5 += block.above_5;
    for (std::size_t band = 0; band < 3; ++band) {
      result.band_delta_e_itp_mean[band] += block.band_sum[band];
      result.band_pixels[band] += block.band_count[band];
    }
  }
  const auto count = static_cast<double>(result.pixels);
  result.delta_e_itp_mean = delta_sum / count;
  result.fraction_above_1 = static_cast<double>(above_1) / count;
  result.fraction_above_2 = static_cast<double>(above_2) / count;
  result.fraction_above_5 = static_cast<double>(above_5) / count;
  result.reference_mean = reference_luminance / count;
  result.candidate_mean = candidate_luminance / count;
  for (std::size_t band = 0; band < 3; ++band) {
    if (result.band_pixels[band] != 0) {
      result.band_delta_e_itp_mean[band] /= static_cast<double>(result.band_pixels[band]);
    }
  }
  const double mse = squared_pq_error / (count * 3.0);
  result.psnr_pq_db = mse > 0.0 ? 10.0 * std::log10(1.0 / mse)
                                : std::numeric_limits<double>::infinity();

  // The upper edge of the bin that contains the requested rank: a percentile is
  // reported as "no worse than", never rounded down past the pixels it covers.
  // The last bin is open-ended, so a rank that lands there can only honestly be
  // bounded by the maximum.
  const auto percentile = [&](double fraction) {
    const auto rank = static_cast<std::uint64_t>(
        std::ceil(fraction * static_cast<double>(result.pixels)));
    std::uint64_t cumulative = 0;
    for (std::size_t bin = 0; bin + 1U < kBins; ++bin) {
      cumulative += histogram[bin];
      if (cumulative >= std::max<std::uint64_t>(rank, 1U)) {
        return std::min(result.delta_e_itp_max,
                        static_cast<float>(bin + 1U) * kBinWidth);
      }
    }
    return result.delta_e_itp_max;
  };
  result.delta_e_itp_p50 = percentile(0.50);
  result.delta_e_itp_p95 = percentile(0.95);
  result.delta_e_itp_p99 = percentile(0.99);
  result.delta_e_itp_p999 = percentile(0.999);
  return result;
}

}  // namespace hyperdr

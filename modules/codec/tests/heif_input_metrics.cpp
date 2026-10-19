#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <optional>

#include "hyperdr/foundation/json.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/transfer.hpp"
// Usage: heif_input_metrics BEFORE.f32 AFTER.f32 WIDTH HEIGHT BIT_DEPTH
// Headerless float32 RGB is oriented linear Display P3. The encoded-domain
// statistic applies to SDR sRGB-transfer code values; HDR uses PQ/ITP instead.
int main(int argc, char** argv) {
  try {
    if (argc != 6) return 2;
    unsigned w = std::stoul(argv[3]), h = std::stoul(argv[4]), bits = std::stoul(argv[5]);
    if (!w || !h || (bits != 8 && bits != 10))
      throw std::invalid_argument("expected nonzero RGB dimensions and 8/10-bit codes");
    auto load = [&](char* p) {
      hyperdr::FloatImage a(w, h, 3);
      std::ifstream f(p, std::ios::binary);
      f.read(reinterpret_cast<char*>(a.pixels.data()), a.pixels.size() * 4);
      if (!f || f.peek() != EOF) throw std::runtime_error("wrong dump length");
      return a;
    };
    auto a = load(argv[1]), b = load(argv[2]);
    auto m = hyperdr::measure_hdr_fidelity(a, b);
    double mse = 0;
    std::vector<size_t> bins(4097);
    for (size_t i = 0; i < a.pixels.size(); ++i) {
      if (!std::isfinite(a.pixels[i]) || !std::isfinite(b.pixels[i]))
        throw std::invalid_argument("non-finite comparison pixel");
      double e = a.pixels[i] - b.pixels[i];
      mse += e * e;
      auto code = [&](float n) {
        return std::clamp(hyperdr::srgb_oetf(n), 0.F, 1.F) * ((1U << bits) - 1);
      };
      auto d = std::abs(code(a.pixels[i]) - code(b.pixels[i]));
      bins[std::min<size_t>(4096, std::ceil(d))]++;
    }
    size_t n = 0, p99 = 0;
    for (; p99 < bins.size(); ++p99) {
      n += bins[p99];
      if (n >= std::ceil(a.pixels.size() * .99)) break;
    }
    hyperdr::json::Writer j;
    j.begin_object()
        .member("psnr_pq_db",
                std::isfinite(m.psnr_pq_db) ? std::optional<double>{m.psnr_pq_db} : std::nullopt)
        .member("psnr_pq_infinite", !std::isfinite(m.psnr_pq_db))
        .member("delta_itp_p99", m.delta_e_itp_p99)
        .member("mean_luminance_relative_error", std::abs(m.candidate_mean - m.reference_mean) /
                                                     std::max(1e-12, std::abs(m.reference_mean)))
        .member(
            "psnr_linear_db",
            mse > 0 ? std::optional<double>{10 * std::log10(a.pixels.size() / mse)} : std::nullopt)
        .member("pixels_identical", mse == 0)
        .member("encoded_difference_p99_upper_codes", p99)
        .end_object();
    std::cout << j.take() << '\n';
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}

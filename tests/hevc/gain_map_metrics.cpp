// E4q criterion 3 for a gain-map JPEG: the error the gain map adds on top of
// its base, and the robust peak.
//
//     c++ -std=c++20 -O2 tests/hevc/gain_map_metrics.cpp -o build/gain_map_metrics
//     build/gain_map_metrics REF_SDR REF_HDR CAND_SDR CAND_HDR
//
// Inputs are float dumps (three uint32 width, height, 3, then float32 linear
// Display P3 RGB rows): the uncompressed reference renditions, and a decoder's
// base and HDR readback (imageio_probe's HYPERDR_PROBE_DUMP_SDR / _HDR, or our
// own reconstruction). Over bright pixels (reference SDR luminance >= 0.02,
// imageio_probe's rule) `extra_mean` / `extra_p99` are the mean / p99 of the
// HDR |dlog2 Y| against the reference HDR minus those of the base |dlog2 Y|
// against the reference SDR (limits 0.01 / 0.04 stops). Peaks use each pixel's
// maximum channel: `pixmax_p9999_ratio` (limit 2%), the absolute maximum and
// the counts over 1.06 and 1.25 for near-SDR renderings. Prints one JSON line.
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>
struct Image { unsigned w, h, c; std::vector<float> p; };
Image read(const char* file) {
  std::ifstream f(file, std::ios::binary); Image i;
  f.read((char*)&i.w, 4); f.read((char*)&i.h, 4); f.read((char*)&i.c, 4);
  if (!f || i.c != 3) throw std::runtime_error(std::string("bad float image ") + file);
  i.p.resize((size_t)i.w * i.h * 3); f.read((char*)i.p.data(), i.p.size() * 4);
  if (!f) throw std::runtime_error(std::string("short float image ") + file);
  return i;
}
float pct(std::vector<float> v, double q) {
  if (v.empty()) return 0;
  const size_t n = std::min(v.size() - 1, (size_t)(v.size() * q));
  std::nth_element(v.begin(), v.begin() + n, v.end()); return v[n];
}
double mean(const std::vector<float>& v) { double s = 0; for (float x : v) s += x; return v.empty() ? 0 : s / v.size(); }
int main(int argc, char** argv) { try {
  if (argc != 5) throw std::runtime_error("usage: metrics REF_SDR REF_HDR CAND_SDR CAND_HDR");
  const auto rs = read(argv[1]), rh = read(argv[2]), cs = read(argv[3]), ch = read(argv[4]);
  for (const auto* i : {&rh, &cs, &ch}) if (i->w != rs.w || i->h != rs.h) throw std::runtime_error("shape mismatch");
  const float k[]{.22897456f, .69173852f, .07928691f};
  auto luma = [&](const Image& i, size_t p) { return i.p[p] * k[0] + i.p[p + 1] * k[1] + i.p[p + 2] * k[2]; };
  std::vector<float> eh, es, ed, rm, cm; size_t n = (size_t)rs.w * rs.h;
  eh.reserve(n); es.reserve(n); ed.reserve(n); rm.reserve(n); cm.reserve(n);
  float rpeak = 0, cpeak = 0; size_t over106 = 0, over125 = 0;
  for (size_t p = 0; p < rs.p.size(); p += 3) {
    const float r = std::max({rh.p[p], rh.p[p + 1], rh.p[p + 2]}), c = std::max({ch.p[p], ch.p[p + 1], ch.p[p + 2]});
    rm.push_back(r); cm.push_back(c); rpeak = std::max(rpeak, r); cpeak = std::max(cpeak, c);
    over106 += c > 1.06f; over125 += c > 1.25f;
    const float ys = luma(rs, p);
    if (ys < .02f) continue;
    const float h = std::abs(std::log2(std::max(luma(ch, p), 1e-5f) / std::max(luma(rh, p), 1e-5f)));
    const float s = std::abs(std::log2(std::max(luma(cs, p), 1e-5f) / ys));
    eh.push_back(h); es.push_back(s); ed.push_back(h - s);
  }
  const float r9999 = pct(rm, .9999), c9999 = pct(cm, .9999);
  std::cout << "{\"width\":" << rs.w << ",\"height\":" << rs.h
            << ",\"bright_fraction\":" << double(eh.size()) / n
            << ",\"hdr_mean\":" << mean(eh) << ",\"hdr_p99\":" << pct(eh, .99)
            << ",\"base_mean\":" << mean(es) << ",\"base_p99\":" << pct(es, .99)
            << ",\"extra_mean\":" << mean(eh) - mean(es) << ",\"extra_p99\":" << pct(eh, .99) - pct(es, .99)
            << ",\"pixel_extra_mean\":" << mean(ed) << ",\"pixel_extra_p99\":" << pct(ed, .99)
            << ",\"reference_pixmax_p9999\":" << r9999 << ",\"candidate_pixmax_p9999\":" << c9999
            << ",\"pixmax_p9999_ratio\":" << c9999 / r9999
            << ",\"reference_peak\":" << rpeak << ",\"candidate_peak\":" << cpeak
            << ",\"peak_ratio\":" << cpeak / rpeak
            << ",\"pixmax_over_1.06_fraction\":" << double(over106) / n
            << ",\"pixmax_over_1.25_count\":" << over125 << "}\n";
  return 0;
} catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; } }

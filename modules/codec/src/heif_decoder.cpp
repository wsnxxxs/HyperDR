#include "internal/heif_decoder.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "hevc/hevc.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/resample.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/look/grid.hpp"
#include "internal/budget.hpp"
#include "internal/cicp.hpp"
#include "internal/heif_color.hpp"
#include "internal/metadata.hpp"
namespace hyperdr::codec {
namespace {
struct Geometry {
  int a = 1, b = 0, c = 0, d = 1;
  std::int64_t tx = 0, ty = 0;
  unsigned width, height;
  explicit Geometry(const HeifImagePlan& plan) : width(plan.width), height(plan.height) {
    auto compose = [&](int aa, int bb, int cc, int dd, std::int64_t x, std::int64_t y) {
      const auto na = aa * a + bb * c, nb = aa * b + bb * d, nc = cc * a + dd * c,
                 nd = cc * b + dd * d;
      const auto nx = aa * tx + bb * ty + x, ny = cc * tx + dd * ty + y;
      a = na;
      b = nb;
      c = nc;
      d = nd;
      tx = nx;
      ty = ny;
    };
    for (const auto& t : plan.transforms) {
      if (t.type == "clap") {
        compose(1, 0, 0, 1, -std::int64_t(t.left), -std::int64_t(t.top));
        width = t.width;
        height = t.height;
      } else if (t.type == "imir") {
        // ISO/IEC 23008-12 axis 0 exchanges top and bottom (a vertical flip),
        // axis 1 left and right; ImageIO and the previous libheif path agree.
        if (t.value == 0)
          compose(1, 0, 0, -1, 0, height - 1);
        else
          compose(-1, 0, 0, 1, width - 1, 0);
      } else if (t.type == "irot") {
        if (t.value == 1) {
          compose(0, 1, -1, 0, 0, width - 1);
          std::swap(width, height);
        } else if (t.value == 2)
          compose(-1, 0, 0, -1, width - 1, height - 1);
        else if (t.value == 3) {
          compose(0, -1, 1, 0, height - 1, 0);
          std::swap(width, height);
        }
      }
    }
  }
  std::pair<std::int64_t, std::int64_t> map(unsigned x, unsigned y) const {
    return {a * std::int64_t(x) + b * std::int64_t(y) + tx,
            c * std::int64_t(x) + d * std::int64_t(y) + ty};
  }
};
struct Progress {
  const RawDecodeOptions& options;
  std::string_view path;
  std::size_t done = 0, total = 0;
  void tick(std::size_t n) {
    if (options.progress_sink)
      options.progress_sink->on_progress(
          {"decode", path, .9 * double(done + n) / std::max<std::size_t>(1, total), {}});
  }
  void finish() {
    if (options.progress_sink) options.progress_sink->on_progress({"decode", path, 1, {}});
  }
};
void tiles(const HeifFile& file, const HeifImagePlan& plan, const hevc::DecodedTileSink& sink,
           Progress* progress = nullptr) {
  std::vector<std::uint8_t> joined;
  hevc::DecodeParams params;
  if (progress) params.progress = [&](std::size_t n, std::size_t) { progress->tick(n); };
  hevc::decode_item(
      plan.config, plan.tiles.size(),
      [&](std::size_t i) -> std::span<const std::uint8_t> {
        const auto extents = plan.tiles[i].extents;
        if (extents.size() == 1) return file.bytes.subspan(extents[0].offset, extents[0].length);
        joined = file.item_bytes(plan.tiles[i].id);
        return joined;
      },
      sink, params);
  if (progress) progress->done += plan.tiles.size();
}
// Full-size writes are disjoint even after rotation. A reduced output
// accumulates weighted sums, so `put` must then be called serially in a fixed
// tile/row/pixel order (callers stage converted rows; `reduced` tells them).
class Output {
 public:
  Geometry geometry;
  FloatImage image;
  bool reduced, budget_limited;
  Output(const HeifImagePlan& plan, unsigned channels, unsigned edge = 0) : geometry(plan) {
    auto size = raster_decode_plan(geometry.width, geometry.height, edge);
    image = FloatImage(size.width, size.height, channels);
    budget_limited = size.budget_limited;
    reduced = size.width != geometry.width || size.height != geometry.height;
  }
  void put(unsigned sx, unsigned sy, const float* value) {
    const auto [x, y] = geometry.map(sx, sy);
    if (x < 0 || y < 0 || x >= geometry.width || y >= geometry.height) return;
    if (!reduced) {
      std::copy_n(value, image.channels,
                  image.pixels.data() + (std::size_t(y) * image.width + x) * image.channels);
      return;
    }
    const double left = double(x) * image.width / geometry.width,
                 right = double(x + 1) * image.width / geometry.width;
    const double top = double(y) * image.height / geometry.height,
                 bottom = double(y + 1) * image.height / geometry.height;
    for (unsigned yy = unsigned(top); yy < std::min(image.height, unsigned(std::ceil(bottom)));
         ++yy)
      for (unsigned xx = unsigned(left); xx < std::min(image.width, unsigned(std::ceil(right)));
           ++xx) {
        const float weight = (std::min(right, double(xx + 1)) - std::max(left, double(xx))) *
                             (std::min(bottom, double(yy + 1)) - std::max(top, double(yy)));
        auto* p = image.pixels.data() + (std::size_t(yy) * image.width + xx) * image.channels;
        for (unsigned ch = 0; ch < image.channels; ++ch) p[ch] += value[ch] * weight;
      }
  }
};
FloatImage code_plane(const HeifFile& file, const HeifImagePlan& plan, unsigned channels,
                      Progress* progress) {
  if (channels != 1 && channels != 3) throw HeifReadError("invalid HEIF gain channels");
  Output out(plan, channels);
  const float maximum = (1U << plan.config.bit_depth) - 1;
  tiles(
      file, plan,
      [&](std::size_t index, hevc::DecodedPicture&& p) {
        auto x0 = unsigned(index % plan.columns) * plan.tile_width,
             y0 = unsigned(index / plan.columns) * plan.tile_height;
        if (channels == 1) {
          const auto row = [&](unsigned y) {
            for (unsigned x = 0; x < p.width && x0 + x < plan.width && y0 + y < plan.height; ++x) {
              float v = p.luma_at(x, y) / maximum;
              out.put(x0 + x, y0 + y, &v);
            }
          };
          if (out.reduced) {
            for (unsigned y = 0; y < p.height; ++y) row(y);
          } else {
            parallel_for_rows(p.height, row);
          }
        } else {
          auto params = hevc::conversion_params(plan.config, plan.color ? &*plan.color : nullptr);
          // Rows convert in parallel either way. A reduced output accumulates
          // weighted sums, so those rows are staged and added in order after.
          std::vector<float> staged(out.reduced ? std::size_t(p.height) * p.width * 3 : 0);
          hevc::yuv_to_rgb(p, params, [&](unsigned y, std::span<const float> row) {
            if (out.reduced) {
              std::copy_n(row.data(), std::size_t(p.width) * 3,
                          staged.data() + std::size_t(y) * p.width * 3);
              return;
            }
            for (unsigned x = 0; x < p.width && x0 + x < plan.width && y0 + y < plan.height; ++x) {
              float v[3]{row[x * 3], row[x * 3 + 1], row[x * 3 + 2]};
              out.put(x0 + x, y0 + y, v);
            }
          });
          if (out.reduced)
            for (unsigned y = 0; y < p.height; ++y)
              for (unsigned x = 0; x < p.width && x0 + x < plan.width && y0 + y < plan.height; ++x)
                out.put(x0 + x, y0 + y, staged.data() + (std::size_t(y) * p.width + x) * 3);
        }
      },
      progress);
  return std::move(out.image);
}
// Alpha is sampled per source pixel, so it is kept at the oriented source size
// whatever the output is reduced to. Codes are at most 10 bits: two bytes a
// pixel, and the canvas is bounded by tiled_canvas_ok.
class AlphaPlane {
 public:
  unsigned width = 0, height = 0;
  [[nodiscard]] bool empty() const { return codes_.empty(); }
  void allocate(unsigned w, unsigned h, float maximum) {
    width = w;
    height = h;
    maximum_ = maximum;
    codes_.assign(std::size_t(w) * h, 0);
  }
  void set(unsigned x, unsigned y, std::uint16_t code) { codes_[std::size_t(y) * width + x] = code; }
  [[nodiscard]] float at(unsigned x, unsigned y) const {
    return float(codes_[std::size_t(y) * width + x]) / maximum_;
  }

 private:
  std::vector<std::uint16_t> codes_;
  float maximum_ = 1;
};
AlphaPlane decode_alpha_plane(const HeifFile& file, const HeifImagePlan& plan, Progress* progress) {
  const Geometry geometry(plan);
  AlphaPlane alpha;
  const float maximum = (1U << plan.config.bit_depth) - 1;
  alpha.allocate(geometry.width, geometry.height, maximum);
  tiles(
      file, plan,
      [&](std::size_t index, hevc::DecodedPicture&& p) {
        auto x0 = unsigned(index % plan.columns) * plan.tile_width,
             y0 = unsigned(index / plan.columns) * plan.tile_height;
        // Rows write disjoint destination pixels after any rotation or flip.
        parallel_for_rows(p.height, [&](unsigned y) {
          for (unsigned x = 0; x < p.width && x0 + x < plan.width && y0 + y < plan.height; ++x) {
            const auto [mx, my] = geometry.map(x0 + x, y0 + y);
            if (mx >= 0 && my >= 0 && mx < geometry.width && my < geometry.height)
              alpha.set(unsigned(mx), unsigned(my), std::uint16_t(p.luma_at(x, y)));
          }
        });
      },
      progress);
  return alpha;
}
// Box-average the alpha plane onto the (budget-reduced) output grid.
FloatImage reduce_alpha(const AlphaPlane& alpha, unsigned width, unsigned height) {
  FloatImage out(width, height, 1);
  parallel_for_rows(height, [&](unsigned y) {
    const double top = double(y) * alpha.height / height,
                 bottom = double(y + 1) * alpha.height / height;
    for (unsigned x = 0; x < width; ++x) {
      const double left = double(x) * alpha.width / width,
                   right = double(x + 1) * alpha.width / width;
      double sum = 0, total = 0;
      for (unsigned sy = unsigned(top); sy < std::min(alpha.height, unsigned(std::ceil(bottom)));
           ++sy)
        for (unsigned sx = unsigned(left); sx < std::min(alpha.width, unsigned(std::ceil(right)));
             ++sx) {
          const double weight = (std::min(right, double(sx + 1)) - std::max(left, double(sx))) *
                                (std::min(bottom, double(sy + 1)) - std::max(top, double(sy)));
          sum += alpha.at(sx, sy) * weight;
          total += weight;
        }
      out.at(x, y, 0) = total > 0 ? float(sum / total) : 0;
    }
  });
  return out;
}
SourceColor color_for(const HeifImagePlan& plan, ColorGamut gamut) {
  SourceColor color(gamut);
  color.icc.assign(plan.icc.begin(), plan.icc.end());
  if (!color.icc.empty()) color.source = "icc";
  if (plan.color) {
    auto transfer = plan.color->transfer;
    if (color.icc.empty() || transfer == kCicpTransferPq || transfer == kCicpTransferHlg) {
      color.source = "cicp";
      color.primaries = plan.color->primaries;
      color.transfer = transfer;
      if (transfer == kCicpTransferPq || transfer == kCicpTransferHlg) color.icc.clear();
      if (cicp_primaries_unspecified(color.primaries))
        color.primaries = cicp_primaries_for_gamut(gamut);
    }
  }
  return color;
}
DecodedImage primary(const HeifFile& file, const HeifImagePlan& plan, ColorGamut gamut,
                     unsigned edge, bool preserve_alpha, AlphaPlane* alpha_out,
                     Progress* progress) {
  const auto color = color_for(plan, gamut);
  auto alpha_plan = file.resolve_alpha(plan.item_id, HeifCanvas::Tiled, &plan);
  AlphaPlane alpha;
  if (alpha_plan) alpha = decode_alpha_plane(file, alpha_plan->image, progress);
  Output out(plan, 3, edge);
  if (alpha_plan && (alpha.width != out.geometry.width || alpha.height != out.geometry.height))
    throw HeifReadError("HEIF alpha dimensions differ after transforms");
  const auto alpha_type = !alpha_plan                 ? RgbAlpha::None
                          : alpha_plan->premultiplied ? RgbAlpha::Premultiplied
                                                      : RgbAlpha::Straight;
  const FloatRgbRowTransform transform(color);
  tiles(
      file, plan,
      [&](std::size_t index, hevc::DecodedPicture&& p) {
        auto x0 = unsigned(index % plan.columns) * plan.tile_width,
             y0 = unsigned(index / plan.columns) * plan.tile_height;
        auto params = hevc::conversion_params(plan.config, plan.color ? &*plan.color : nullptr);
        // The conversion and the colour transform run on parallel rows; a
        // reduced output stages the converted rows and accumulates them in a
        // fixed order afterwards, so worker count cannot change a sum.
        std::vector<float> staged(out.reduced ? std::size_t(p.height) * p.width * 3 : 0);
        hevc::yuv_to_rgb(p, params, [&](unsigned y, std::span<const float> row) {
          if (y0 + y >= plan.height) return;
          std::vector<float> unassociated;
          std::vector<float> linear(std::size_t(p.width) * 3);
          if (alpha_type == RgbAlpha::Premultiplied) {
            unassociated.assign(row.begin(), row.end());
            for (unsigned x = 0; x < p.width; ++x) {
              const auto [ax, ay] = out.geometry.map(x0 + x, y0 + y);
              const float a = ax >= 0 && ay >= 0 && ax < alpha.width && ay < alpha.height
                                  ? alpha.at(unsigned(ax), unsigned(ay))
                                  : 0;
              for (unsigned c = 0; c < 3; ++c)
                unassociated[x * 3 + c] = a > 0 ? unassociated[x * 3 + c] / a : 0;
            }
            row = unassociated;
          }
          transform.convert(row.data(), linear.data(), p.width);
          if (alpha_plan && !preserve_alpha) {
            for (unsigned x = 0; x < p.width; ++x) {
              const auto [ax, ay] = out.geometry.map(x0 + x, y0 + y);
              const float a = ax >= 0 && ay >= 0 && ax < alpha.width && ay < alpha.height
                                  ? alpha.at(unsigned(ax), unsigned(ay))
                                  : 0;
              for (unsigned c = 0; c < 3; ++c) linear[x * 3 + c] *= a;
            }
          }
          if (out.reduced) {
            std::copy(linear.begin(), linear.end(), staged.begin() + std::size_t(y) * p.width * 3);
            return;
          }
          for (unsigned x = 0; x < p.width && x0 + x < plan.width; ++x)
            out.put(x0 + x, y0 + y, linear.data() + x * 3);
        });
        if (out.reduced)
          for (unsigned y = 0; y < p.height && y0 + y < plan.height; ++y)
            for (unsigned x = 0; x < p.width && x0 + x < plan.width; ++x)
              out.put(x0 + x, y0 + y, staged.data() + (std::size_t(y) * p.width + x) * 3);
      },
      progress);
  DecodedImage result;
  result.source_color = describe_source_color(color);
  result.linear_p3 = std::move(out.image);
  result.decode.sensor_width = plan.width;
  result.decode.sensor_height = plan.height;
  result.decode.target_width = out.geometry.width;
  result.decode.target_height = out.geometry.height;
  result.decode.resolution_reduced = out.budget_limited;
  result.decode.decoded_width = result.linear_p3.width;
  result.decode.decoded_height = result.linear_p3.height;
  result.hdr_headroom = transfer_headroom(color.transfer);
  if (result.hdr_headroom > 1 && plan.light && plan.light->maximum)
    result.content_peak_nits = plan.light->maximum;
  result.domain = display_referred_domain(result.hdr_headroom);
  if (alpha_out) *alpha_out = std::move(alpha);
  return result;
}
void composite(DecodedImage& result, const AlphaPlane& source_alpha) {
  if (source_alpha.empty()) return;
  const bool same = source_alpha.width == result.linear_p3.width &&
                    source_alpha.height == result.linear_p3.height;
  FloatImage reduced;
  if (!same) reduced = reduce_alpha(source_alpha, result.linear_p3.width, result.linear_p3.height);
  parallel_for_rows(result.linear_p3.height, [&](unsigned y) {
    for (unsigned x = 0; x < result.linear_p3.width; ++x) {
      const float a = same ? source_alpha.at(x, y) : reduced.at(x, y, 0);
      for (unsigned c = 0; c < 3; ++c) {
        result.linear_p3.at(x, y, c) *= a;
        if (result.authored_sdr) result.authored_sdr->at(x, y, c) *= a;
      }
    }
  });
}
}  // namespace
FloatImage decode_heif_gain(const HeifFile& file, const HeifImagePlan& plan, unsigned channels) {
  return code_plane(file, plan, channels, nullptr);
}
void verify_heif_tiles(const HeifFile& file, const HeifImagePlan& plan) {
  std::size_t seen = 0;
  tiles(file, plan, [&](std::size_t, hevc::DecodedPicture&& p) {
    if (p.width != plan.tile_width || p.height != plan.tile_height ||
        p.bit_depth != plan.config.bit_depth || p.chroma_format != plan.config.chroma_format)
      throw HeifReadError("decoded HEVC tile differs from its configuration");
    ++seen;
  });
  if (seen != plan.tiles.size()) throw HeifReadError("HEVC decoder returned the wrong tile count");
}
HeifAdaptiveParts decode_heif_adaptive_parts(const std::vector<std::uint8_t>& bytes) {
  const auto file = read_heif(bytes);
  const auto plan = file.resolve_gain_map(HeifCanvas::Tiled);
  if (!plan || !plan->metadata) throw HeifReadError("Adaptive HDR HEIC lacks gain map");
  auto base = primary(file, plan->base, RawDecodeOptions{}.default_gamut, 0, true, nullptr, nullptr);
  auto gain = code_plane(file, plan->gain, gain_map_channel_count(*plan->metadata), nullptr);
  return {std::move(base.linear_p3), std::move(gain), *plan->metadata};
}
DecodedImage decode_heic_bytes(const std::vector<std::uint8_t>& bytes,
                               const RawDecodeOptions& options, std::string_view path) {
  const auto file = read_heif(bytes);
  const auto plan = file.resolve_image(0, HeifCanvas::Tiled);
  auto exif_bytes = file.exif();
  auto exif = read_exif(exif_bytes.data(), exif_bytes.size());
  // Only a rotation or mirror property replaces the Exif orientation; a crop
  // does not (the previous libheif path and ImageIO behave the same).
  const bool oriented_by_container =
      std::any_of(plan.transforms.begin(), plan.transforms.end(),
                  [](const HeifTransform& t) { return t.type == "irot" || t.type == "imir"; });
  auto orientation = oriented_by_container ? 1 : exif.orientation.value_or(1);
  const bool iso = std::find(file.brands.begin(), file.brands.end(), "tmap") != file.brands.end() ||
                   file.tmap_references().has_value();
  std::optional<HeifGainMapPlan> gain;
  std::optional<float> legacy_headroom;
  std::string fallback;
  if (iso) {
    const auto inspection = inspect_heif(bytes);
    if (!inspection.structurally_valid || !inspection.has_tmap_brand || !inspection.has_tmap_item ||
        !inspection.has_dimg_reference)
      throw HeifReadError("Adaptive HDR HEIC has invalid tmap structure");
    gain = file.resolve_gain_map(HeifCanvas::Tiled);
    if (!gain || !gain->metadata) throw HeifReadError("Adaptive HDR HEIC lacks gain map");
  } else if (!options.ignore_embedded_gain_map) {
    for (const auto& [id, item] : file.items) {
      auto refs = file.targets(id, "auxl");
      if (std::find(refs.begin(), refs.end(), file.primary_item_id) == refs.end() ||
          file.auxiliary_type(id) != "urn:com:apple:photo:2020:aux:hdrgainmap")
        continue;
      legacy_headroom = read_apple_legacy_gain_headroom(exif_bytes.data(), exif_bytes.size());
      if (!legacy_headroom || *legacy_headroom < 1) {
        fallback = "missing MakerNote headroom";
        break;
      }
      try {
        gain = HeifGainMapPlan{plan, file.resolve_image(id, HeifCanvas::Tiled), {}, 0};
        if (gain->gain.config.bit_depth != 8 || gain->gain.width > plan.width ||
            gain->gain.height > plan.height) {
          gain.reset();
          fallback = "invalid gain map pixels";
        }
      } catch (const Cancelled&) {
        throw;
      } catch (const std::bad_alloc&) {
        throw;
      } catch (const std::exception& e) {
        fallback = e.what();
      }
      break;
    }
  }
  const bool reconstruct = gain && !options.ignore_embedded_gain_map;
  auto alpha_plan = file.resolve_alpha(0, HeifCanvas::Tiled, &plan);
  Progress progress{options, path, 0,
                    plan.tiles.size() + (alpha_plan ? alpha_plan->image.tiles.size() : 0) +
                        (reconstruct ? gain->gain.tiles.size() : 0)};
  AlphaPlane alpha;
  auto result = primary(file, plan, options.default_gamut,
                        reconstruct ? 0 : options.preview_max_edge, reconstruct, &alpha, &progress);
  apply_exif(result, exif);
  if (reconstruct) {
    FloatImage encoded;
    try {
      encoded = code_plane(file, gain->gain,
                           gain->metadata ? gain_map_channel_count(*gain->metadata) : 1, &progress);
    } catch (const Cancelled&) {
      throw;
    } catch (const std::bad_alloc&) {
      throw;
    } catch (const std::exception& e) {
      if (iso) throw;
      fallback = e.what();
      gain.reset();
    }
    if (gain) {
      result.authored_sdr = result.linear_p3;
      if (gain->metadata) {
        const auto& metadata = *gain->metadata;
        const auto count = gain_map_channel_count(metadata);
        result.gain_map.channels = count;
        result.gain_map.base_headroom = std::exp2(rational_value(metadata.base_headroom));
        const float headroom = rational_value(metadata.alternate_headroom);
        result.gain_map.alternate_headroom = std::exp2(headroom);
        for (unsigned c = 0; c < 3; ++c) {
          auto channel = gain_map_channel(metadata, count == 1 ? 0 : c);
          result.gain_map.base_offset[c] = rational_value(channel.base_offset);
          result.gain_map.alternate_offset[c] = rational_value(channel.alternate_offset);
        }
        result.linear_p3 = reconstruct_gain_map(*result.authored_sdr, encoded, metadata, headroom);
        result.source_color.name = "Adaptive HDR (base: " + result.source_color.name + ")";
      } else {
        result.gain_map.channels = 1;
        result.gain_map.base_headroom = 1;
        result.gain_map.alternate_headroom = *legacy_headroom;
        const BilinearGridSampler sampler(encoded.width, encoded.height, result.linear_p3.width,
                                          result.linear_p3.height);
        const GridView grid(encoded.pixels, encoded.width, encoded.height);
        parallel_for_rows(result.linear_p3.height, [&](unsigned y) {
          for (unsigned x = 0; x < result.linear_p3.width; ++x) {
            const float multiplier =
                1.F + (*legacy_headroom - 1.F) * std::pow(sampler.sample(grid, x, y), 2.2F);
            for (unsigned c = 0; c < 3; ++c) result.linear_p3.at(x, y, c) *= multiplier;
          }
        });
      }
      result.hdr_headroom = measured_alternate_headroom(result.linear_p3);
      result.content_peak_nits.reset();
      result.domain = InputDomain::kDualRendition;
    }
    composite(result, alpha);
  }
  if (!fallback.empty()) {
    result.decode.degraded = true;
    result.decode.degradation_reasons.push_back("apple_legacy_gain_map_unusable_sdr_fallback:" +
                                                fallback);
  }
  if (reconstruct && options.preview_max_edge) {
    const auto size = raster_decode_plan(result.linear_p3.width, result.linear_p3.height,
                                         options.preview_max_edge);
    if (size.width != result.linear_p3.width || size.height != result.linear_p3.height) {
      result.linear_p3 = resample_to(std::move(result.linear_p3), size.width, size.height);
      if (result.authored_sdr)
        result.authored_sdr = resample_to(std::move(*result.authored_sdr), size.width, size.height);
      result.decode.decoded_width = size.width;
      result.decode.decoded_height = size.height;
    }
  }
  normalize_orientation(result, orientation);
  progress.finish();
  return result;
}
}  // namespace hyperdr::codec

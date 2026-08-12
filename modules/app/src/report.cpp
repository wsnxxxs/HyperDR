#include "hyperdr/app/report.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/version.hpp"

namespace hyperdr {
namespace {

// The settings block is generated from the schema, so a new setting appears in
// every report without anyone remembering to add it. The previous hand-written
// block listed six of the twenty-one.
void write_settings(json::Writer& writer, const ConvertOptions& options) {
  writer.begin_object("settings");
  for (const auto& setting : settings()) {
    const json::Value value = setting.read(options);
    if (value.is_string()) writer.member(setting.key, value.string());
    else if (value.is_bool()) writer.member(setting.key, value.boolean());
    else writer.member(setting.key, static_cast<float>(value.number()));
  }
  // The encoded depth, as opposed to the requested one: BT.2100 is always 10-bit.
  writer.member("output_depth", is_bt2100_encoding(options.encoding) ? 10 : options.depth);
  writer.end_object();
  writer.begin_object("raw_processing")
      .member("black_level_correction", "LibRaw metadata")
      .member("white_balance", "camera WB")
      .member("digital_gain", options.raw.digital_gain)
      .member("auto_bad_pixel_correction",
              options.raw.auto_bad_pixel_correction)
      .member("bad_pixel_map", path_utf8(options.raw.bad_pixel_map))
      .member("dark_frame", path_utf8(options.raw.dark_frame))
      .member("linearization_lut", path_utf8(options.raw.linearization_lut))
      .member("lens_shading_map", path_utf8(options.raw.lens_shading_map))
      .end_object();
}

void write_stats(json::Writer& writer, const RenderStats& s) {
  writer.begin_object("look")
      .member("exposure_ev", s.exposure_ev)
      .member("ev100", s.ev100)
      .member("target_middle_gray", s.target_middle_gray)
      .end_object();
  writer.begin_object("render")
      .member("headroom_stops", s.headroom_stops)
      .member("headroom_linear", s.headroom_linear)
      .member("rendered_peak", s.rendered_peak)
      .member("headroom_utilization", s.headroom_utilization)
      .member("below_knee_relative_difference_max", s.below_knee_relative_difference_max)
      .member("wide_gamut_fraction", s.wide_gamut_fraction)
      .member("wide_gamut_pixels", s.wide_gamut_pixels)
      .member("wide_gamut_eligible_pixels", s.wide_gamut_eligible_pixels)
      .member("wide_gamut_luminance_threshold", s.wide_gamut_luminance_threshold)
      .end_object();
  writer.begin_object("gain_map")
      .member("gamma", s.gain_gamma)
      .member("min_stops", s.gain_min_stops)
      .member("max_stops", s.gain_max_stops)
      .begin_object("percentiles_stops")
      .member("p50", s.gain_percentiles[0])
      .member("p75", s.gain_percentiles[1])
      .member("p90", s.gain_percentiles[2])
      .member("p95", s.gain_percentiles[3])
      .member("p99", s.gain_percentiles[4])
      .member("p99_9", s.gain_percentiles[5])
      .member("p99_99", s.gain_percentiles[6])
      .member("max", s.gain_percentiles[7])
      .end_object()
      .member("fraction_gt_0_5", s.gain_fraction_gt_0_5)
      .member("fraction_gt_1_0", s.gain_fraction_gt_1_0)
      .member("fraction_gt_2_0", s.gain_fraction_gt_2_0)
      .member("clipped_fraction", s.gain_clipped_fraction)
      .member("local_weight_mean", s.local_weight_mean)
      .member("local_weight_p95", s.local_weight_p95)
      .end_object();
}

}  // namespace

std::string run_report_json(const std::vector<FileResult>& results,
                            const ConvertOptions& options) {
  json::Writer writer(json::Writer::Style::kIndented);
  writer.begin_object().member("schema", 7).member("tool", kVersion);
  write_settings(writer, options);
  writer.begin_array("files");
  for (const auto& result : results) {
    writer.begin_object()
        .member("input", path_utf8(result.input))
        .member("output", path_utf8(result.output))
        .member("success", result.success)
        .member("skipped", result.skipped)
        .member("self_verified", result.self_verified)
        .member("message", result.message)
        .member("sensor_width", result.sensor_width)
        .member("sensor_height", result.sensor_height)
        .member("target_width", result.target_width)
        .member("target_height", result.target_height)
        .member("decoded_width", result.decoded_width)
        .member("decoded_height", result.decoded_height)
        .member("requested_crop_width", result.requested_crop_width)
        .member("requested_crop_height", result.requested_crop_height)
        .member("delivered_crop_width", result.delivered_crop_width)
        .member("delivered_crop_height", result.delivered_crop_height)
        .member("target_dimensions_applied", result.target_dimensions_applied)
        .member("default_crop_present", result.default_crop_present)
        .member("decode_degraded", result.decode_degraded);
    writer.begin_array("decode_degradation_reasons");
    for (const auto& reason : result.decode_degradation_reasons) {
      writer.element(reason);
    }
    writer.end_array();
    writer.member("width", result.width)
        .member("height", result.height)
        .member("exposure_ev", result.exposure_ev)
        .member("headroom_stops", result.headroom_stops)
        .member("gain_min", result.gain_min)
        .member("gain_max", result.gain_max)
        .member("decode_ms", result.decode_ms)
        .member("process_ms", result.process_ms)
        .member("encode_ms", result.encode_ms);
    write_stats(writer, result.stats);
    writer.end_object();
  }
  return writer.end_array().end_object().take() + "\n";
}

void write_run_report(const std::filesystem::path& path,
                      const std::vector<FileResult>& results,
                      const ConvertOptions& options) {
  if (path.empty()) return;
  write_text_file_atomic(path, run_report_json(results, options), true);
}

std::string look_curve_json(const GainMapOptions& gain, unsigned samples) {
  validate_gain_map_options(gain);
  const LookCurve curve =
      build_look_curve(gain.look, nominal_headroom_stops(gain), samples);
  json::Writer writer;
  writer.begin_object()
      .member("schema", 1)
      .member("look", look_mode_name(gain.look.mode))
      .member("samples", curve.sdr.size())
      .member("headroom_stops", curve.headroom_stops)
      .member("headroom_linear", curve.headroom_linear)
      .member("shoulder_output", curve.shoulder_output)
      .member("contrast", gain.look.contrast)
      .member("vibrance", gain.look.vibrance)
      .member("pop", gain.look.pop)
      .member("exposure_bias_ev", gain.exposure_bias_ev)
      .member("gain_strength", gain.gain_strength)
      .begin_object("tone_curve")
      .member("toe_end", curve.curve.toe_end)
      .member("toe_output", curve.curve.toe_output)
      .member("contrast", curve.curve.contrast)
      .member("shoulder_input", curve.curve.shoulder_input)
      .member("shoulder_output", curve.curve.shoulder_output)
      .end_object()
      .begin_array("sdr").elements(curve.sdr).end_array()
      .begin_array("scene").elements(curve.scene).end_array()
      .begin_array("gain_stops").elements(curve.gain_stops).end_array();
  return writer.end_object().take();
}

}  // namespace hyperdr

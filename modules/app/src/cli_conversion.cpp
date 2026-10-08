#include "cli_commands.hpp"

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <iomanip>
#include <iostream>

namespace hyperdr::app::detail {

int convert_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("convert requires an input path");
  ConvertOptions options;
  options.input = path_from_utf8(argv[2]);
  parse_settings(argc, argv, 3, options);
  return run_conversion(options);
}

// Emits the exporter's own global curve so the panel can render a preview from
// it rather than from a second, hand-written approximation of the same maths.
int curve_command(int argc, char** argv) {
  ConvertOptions options;
  unsigned samples = 257;
  parse_settings(argc, argv, 2, options, &samples);
  std::cout << look_curve_json(options.gain, samples) << '\n';
  return 0;
}

int schema_command(int argc, char** argv) {
  for (int i = 2; i < argc; ++i) {
    if (std::string_view(argv[i]) != "--json") {
      throw std::invalid_argument("unknown schema option: " + std::string(argv[i]));
    }
  }
  std::cout << schema_json();
  return 0;
}

int display_curve_command(int argc, char** argv) {
  if (argc < 5) {
    throw std::invalid_argument(
        "display-curve requires reference, candidate, and --headroom");
  }
  const std::filesystem::path reference = path_from_utf8(argv[2]);
  const std::filesystem::path candidate = path_from_utf8(argv[3]);
  std::vector<float> headrooms;
  for (int i = 4; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--headroom") {
      headrooms.push_back(real(next_value(i, argc, argv, arg),
                               "display headroom"));
    } else {
      throw std::invalid_argument("unknown display-curve option: " +
                                  std::string(arg));
    }
  }
  const auto result = compare_gain_map_heic_curve(reference, candidate, headrooms);
  std::cout << std::setprecision(10) << "{\"points\":[";
  for (std::size_t index = 0; index < result.points.size(); ++index) {
    if (index != 0) std::cout << ',';
    const auto& point = result.points[index];
    std::cout << "{\"headroom_stops\":" << point.headroom_stops
              << ",\"mae_linear_p3\":" << point.mae_linear_p3
              << ",\"mse_linear_p3\":" << point.mse_linear_p3
              << ",\"max_abs_error_linear_p3\":"
              << point.max_abs_error_linear_p3
              << ",\"total_values\":" << point.total_values
              << ",\"reference_clamp_values\":"
              << point.reference_clamp_values
              << ",\"candidate_clamp_values\":"
              << point.candidate_clamp_values
              << ",\"total_pixels\":" << point.total_pixels
              << ",\"reference_clamp_pixels\":"
              << point.reference_clamp_pixels
              << ",\"candidate_clamp_pixels\":"
              << point.candidate_clamp_pixels << '}';
  }
  std::cout << "]}\n";
  return 0;
}

}  // namespace hyperdr::app::detail

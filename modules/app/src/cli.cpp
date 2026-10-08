#include "hyperdr/app/cli.hpp"

#include "cli_commands.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/foundation/version.hpp"

#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace hyperdr {
using namespace app::detail;
namespace {

void usage() {
  std::cout
      << "HyperDR " << kVersion
      << " - ARW/DNG/JPEG/PNG/HEIC/AVIF/Ultra HDR to Adaptive HDR, Ultra HDR,"
         " PQ, HLG, AVIF\n\n"
         "Usage:\n"
         "  HyperDR convert <file-or-directory> --output <directory> [options]\n"
         "  HyperDR inspect <file.heic> [--json]\n"
         "  HyperDR raw-metadata <raw-file>\n"
         "  HyperDR verify <file.heic|file.jpg|file.tiff> [--reconstruct <preview.tiff>]\n"
         "                         [--reference <source-image>]\n"
         "  HyperDR display-curve <reference.heic> <candidate.heic>\n"
         "                         --headroom <stops> [--headroom <stops> ...]\n"
         "  HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]\n"
         "                            [--quality <1..100>] [--half-size]\n"
         "                            [--highlight-recovery blend|reconstruct|clip|unclip]\n"
         "                            [--base-only]\n"
         "  HyperDR preview-frame <image> --output <preview.hpf> [look options]\n"
         "                            [--preview-max-edge <pixels>] [--fast-preview]\n"
         "  HyperDR model-gain <image> --ai-model [<id>] [look options]\n"
         "                            (writes a binary gain packet to stdout)\n"
         "                            [--input-tensor <linear-p3.f32> --tensor-width <px>\n"
         "                             --tensor-height <px>]\n"
         "  HyperDR model-list [--json]                    Emit the model table as JSON\n"
         "  HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>\n"
         "                            [--long-side <pixels>] [--half-size] [look options]\n"
         "  HyperDR curve [look options] [--samples <N>]   Emit the tone curve as JSON\n"
         "  HyperDR schema                                 Emit the settings schema as JSON\n\n"
         "Convert settings:\n"
      << settings_usage_text()
      << "\nConvert plumbing:\n"
         "  --output <directory>               Where converted images are written\n"
         "  --report <file.json>               Write a structured run report\n"
         "  --external-gain <file.f32>         Use an external canonical gain grid\n"
         "  --external-gain-report <file.json> Required sidecar for that gain grid\n"
         "  --ai-model [<id>]                   Run an embedded native gain model\n"
         "                                     (research-cnn-v1,\n"
         "                                      research-exif-v1; default research-cnn-v1)\n"
         "  --input-tensor <file.f32>          Feed model-gain a developed HWC linear-P3\n"
         "                                     float32 tensor instead of decoding an image\n"
         "  --tensor-width <pixels>            Width of --input-tensor (required with it)\n"
         "  --tensor-height <pixels>           Height of --input-tensor (required with it)\n"
         "  --ai-brightness <EV>               Post-model SDR brightness\n"
         "  --ai-contrast <slope>              Post-model contrast around diffuse white\n"
         "  --ai-shadows <EV>                  Post-model shadow lift\n"
         "  --ai-highlights <stops>            Post-model highlight gain adjustment\n"
         "  --ai-hdr-range <stops>             Post-model gain-range cap\n"
         "  --ai-expansion-start <0..1>        Post-model gain luma knee\n"
          "  --allow-legacy-external-gain      Allow frozen v1 normalized sidecars\n"
          "  --decode-cache <directory>         Reuse decoded buffers across look-only reruns\n"
          "  --fast-preview                     Explicitly allow RAW half-size decoding\n"
          "  --raw-bad-pixels <file>             Visible-area bad-pixel coordinates\n"
          "  --raw-dark-frame <file>              Visible-area 16-bit dark-frame PGM\n"
          "  --lut <file.cube>                  Creative 1D/3D colour LUT\n"
          "  --raw-linearization-lut <file>      N code-to-code LUT for RAW linearization\n"
          "  --raw-lens-shading <file>           Text gain map: width height channels + gains\n";
  if (!kCodecsAvailable) {
    std::cout << "\nThis build was configured with HYPERDR_WITH_CODECS=OFF: the renderer\n"
                 "and its self-tests are present, but no format can be read or written.\n";
  }
}

}  // namespace

int run_cli(int argc, char** argv) {
  if (argc < 2 || std::string_view(argv[1]) == "--help" ||
      std::string_view(argv[1]) == "-h") {
    usage();
    return argc < 2 ? 2 : 0;
  }
  const std::string_view command = argv[1];
  if (command == "convert") return convert_command(argc, argv);
  if (command == "curve") return curve_command(argc, argv);
  if (command == "schema") return schema_command(argc, argv);
  if (command == "display-curve") return display_curve_command(argc, argv);
  if (command == "raw-metadata") return raw_metadata_command(argc, argv);
  if (command == "inspect") return inspect_command(argc, argv);
  if (command == "verify") return verify_command(argc, argv);
  if (command == "thumbnail") return thumbnail_command(argc, argv);
  if (command == "preview-frame") return preview_frame_command(argc, argv);
  if (command == "preview-worker") return preview_worker_command();
  if (command == "model-gain") return model_gain_command(argc, argv);
  if (command == "model-input") return model_input_command(argc, argv);
  if (command == "model-list") return model_list_command(argc, argv);
  throw std::invalid_argument("unknown command: " + std::string(command));
}

}  // namespace hyperdr

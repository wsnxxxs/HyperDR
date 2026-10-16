#include "cli_commands.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include <iostream>

namespace hyperdr::app::detail {

int preview_frame_command(int argc, char** argv, PreviewSession* session,
                          std::vector<std::uint8_t>* packet) {
  if (argc < 3) throw std::invalid_argument("preview-frame requires one input image");
  ConvertOptions options;
  options.input = path_from_utf8(argv[2]);
  PreviewRegion region;
  parse_settings(argc, argv, 3, options, nullptr, &region);
  if (options.output_directory.empty()) throw std::invalid_argument("preview-frame --output is required");
  if (same_path(options.input, options.output_directory)) {
    throw std::invalid_argument("preview-frame output must differ from input image");
  }
  // The worker can switch sources between requests; source binding lives in
  // the request for that adapter. C ABI sessions stay bound to one source.
  auto owned = session ? nullptr : Engine().preview_open(options.input);
  auto bytes = (session ? session : owned.get())->render(options, region, nullptr, packet != nullptr);
  if (packet) *packet = std::move(bytes);
  else write_binary_file_atomic(options.output_directory, bytes, true);
  return 0;
}

int preview_worker_command() {
  set_stdout_binary();
  PreviewSession session({}, {}, {});
  std::cout << "{\"schema\":\"hyperdr.preview-worker/v1\"}\n" << std::flush;
  std::string line;
  while (std::getline(std::cin, line)) {
    try {
      const auto request = json::parse(line);
      std::vector<std::string> arguments{"HyperDR", "preview-frame"};
      for (const auto& value : request.array()) arguments.push_back(value.string());
      std::vector<char*> argv;
      for (auto& argument : arguments) argv.push_back(argument.data());
      std::vector<std::uint8_t> packet;
      if (arguments.size() < 3) throw std::invalid_argument("preview-frame requires one input image");
      preview_frame_command(static_cast<int>(argv.size()), argv.data(), &session, &packet);
      std::cout << "{\"size\":" << packet.size() << "}\n";
      std::cout.write(reinterpret_cast<const char*>(packet.data()), packet.size());
    } catch (const std::exception& error) {
      std::cout << "{\"size\":0,\"error\":\"" << json::escape(error.what()) << "\"}\n";
    }
    std::cout.flush();
  }
  return 0;
}

}  // namespace hyperdr::app::detail

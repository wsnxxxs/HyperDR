#include "hyperdr/app/cli.hpp"
#include "hyperdr/model/ncnn_runtime.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <exception>
#include <iostream>
#include <string>
#include <vector>

#ifdef _WIN32
int wmain(int argc, wchar_t** wide_argv) {
#else
int main(int argc, char** argv) {
#endif
  try {
#if HYPERDR_WITH_NCNN
    hyperdr::install_embedded_ncnn_runtime();
#endif
#ifdef _WIN32
    std::vector<std::string> utf8_args;
    utf8_args.reserve(argc);
    for (int i = 0; i < argc; ++i) {
      utf8_args.push_back(hyperdr::path_utf8(std::filesystem::path(wide_argv[i])));
    }
    std::vector<char*> argv;
    argv.reserve(argc);
    for (auto& arg : utf8_args) argv.push_back(arg.data());
    return hyperdr::run_cli(argc, argv.data());
#else
    return hyperdr::run_cli(argc, argv);
#endif
  } catch (const std::exception& e) {
    std::cerr << "fatal: " << e.what() << '\n';
    return 2;
  }
}

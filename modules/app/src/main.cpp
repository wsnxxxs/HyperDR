#include "hyperdr/app/cli.hpp"
#include "hyperdr/model/ncnn_runtime.hpp"

#include <exception>
#include <iostream>

int main(int argc, char** argv) {
  try {
#if HYPERDR_WITH_NCNN
    hyperdr::install_embedded_ncnn_runtime();
#endif
    return hyperdr::run_cli(argc, argv);
  } catch (const std::exception& e) {
    std::cerr << "fatal: " << e.what() << '\n';
    return 2;
  }
}

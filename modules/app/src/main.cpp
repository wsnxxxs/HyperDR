#include "hyperdr/app/cli.hpp"

#include <exception>
#include <iostream>

int main(int argc, char** argv) {
  try {
    return hyperdr::run_cli(argc, argv);
  } catch (const std::exception& e) {
    std::cerr << "fatal: " << e.what() << '\n';
    return 2;
  }
}

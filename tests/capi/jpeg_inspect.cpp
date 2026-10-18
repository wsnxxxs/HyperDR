// Test-only bridge: run the real CLI inspect command on the C pthread.
#include "hyperdr/app/cli.hpp"
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
extern "C" int e4_inspect_jpeg(const char* path, char** output) {
  *output=nullptr;
  std::ostringstream text;
  auto* previous=std::cout.rdbuf(text.rdbuf());
  try {
    std::string app="HyperDR", command="inspect", file=path, flag="--json";
    char* args[]{app.data(),command.data(),file.data(),flag.data()};
    const int status=hyperdr::run_cli(4,args);
    std::cout.rdbuf(previous);
    if(status)return status;
    const auto bytes=text.str();
    *output=static_cast<char*>(std::malloc(bytes.size()+1));
    if(!*output)return 1;
    std::memcpy(*output,bytes.c_str(),bytes.size()+1);
    return 0;
  } catch (...) {std::cout.rdbuf(previous);return 1;}
}

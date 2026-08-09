cmake_minimum_required(VERSION 3.25)
project(HyperDRMacOST2Reference LANGUAGES CXX)

add_executable(hyperdr_macos_t2_reference
  cpp_reference.cpp
  ../../modules/gainmap/src/reconstruct.cpp
  ../../modules/container/src/iso_gain_map.cpp)
target_compile_features(hyperdr_macos_t2_reference PRIVATE cxx_std_20)
set_target_properties(hyperdr_macos_t2_reference PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(hyperdr_macos_t2_reference PRIVATE
  ../../modules/gainmap/include
  ../../modules/container/include
  ../../modules/foundation/include
  ../../modules/image/include)
if(MSVC)
  target_compile_options(hyperdr_macos_t2_reference PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(hyperdr_macos_t2_reference PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
endif()

cmake_minimum_required(VERSION 3.25)
project(HyperDRDisplayGates LANGUAGES CXX)

# Standalone, like tests/macos_t2: the gate harnesses are run by hand against a
# corpus and are not part of the unit-test suite.
add_executable(hyperdr_profile_regression
  profile_regression.cpp
  ../../modules/container/src/iso_gain_map.cpp)
target_compile_features(hyperdr_profile_regression PRIVATE cxx_std_20)
set_target_properties(hyperdr_profile_regression PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(hyperdr_profile_regression PRIVATE
  ../../modules/container/include
  ../../modules/foundation/include)
if(MSVC)
  target_compile_options(hyperdr_profile_regression PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(hyperdr_profile_regression PRIVATE
    -Wall -Wextra -Wpedantic -Werror)
endif()

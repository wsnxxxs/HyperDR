cmake_minimum_required(VERSION 3.25)
project(HyperDR VERSION 1.0.0 LANGUAGES CXX)

# Core modules are also linked into the C ABI shared library.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)

# HyperDR is built as seven layered modules under modules/, each with its own
# public include root:
#
#   foundation  numeric helpers, JSON, file IO, hashing, the row-parallel pool
#   image       the float image container, colour, transfer functions, resampling
#   look        rendering intent: tone curve, scene analysis, exposure, headroom
#   container   on-disk metadata: HEIF boxes, ISO 21496-1 gain map, Exif/XMP
#   gainmap     SDR base + gain map rendering and reconstruction
#   codec       reading and writing image files (the only layer with third-party
#               image dependencies)
#   app         settings, discovery, resumable batches, reporting, the CLI
#
# Dependencies run strictly upward, and because each module exposes only its own
# include/ root a module cannot include a header from a layer it does not link:
# an accidental upward dependency fails to compile rather than merely being
# impolite.

option(HYPERDR_WITH_CODECS "Build Apple and vcpkg image codec support" ON)
option(HYPERDR_BUILD_TESTS "Build unit tests" ON)
option(HYPERDR_ENABLE_AVX2 "Enable AVX2 code generation for Release builds" OFF)

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(HyperDRCompiler)
include(HyperDRTesting)

find_package(Threads REQUIRED)

include(CheckIPOSupported)
check_ipo_supported(RESULT HYPERDR_IPO_SUPPORTED OUTPUT HYPERDR_IPO_ERROR LANGUAGES CXX)

include(CTest)

include(HyperDRBuildIdentity)

add_subdirectory(modules/foundation)
add_subdirectory(modules/image)
add_subdirectory(modules/look)
add_subdirectory(modules/container)
add_subdirectory(modules/gainmap)
add_subdirectory(modules/codec)
target_compile_definitions(hyperdr_codec PRIVATE HYPERDR_BUILD_ID="${HYPERDR_BUILD_ID}")
add_subdirectory(modules/app)
add_subdirectory(modules/capi)

option(HYPERDR_BUILD_FUZZERS "Build opt-in LLVM parser fuzz targets" OFF)
if(HYPERDR_BUILD_FUZZERS)
  add_subdirectory(tests/fuzz)
endif()

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
include(HyperDRModel)

find_package(Threads REQUIRED)

include(CheckIPOSupported)
check_ipo_supported(RESULT HYPERDR_IPO_SUPPORTED OUTPUT HYPERDR_IPO_ERROR LANGUAGES CXX)

include(CTest)

hyperdr_configure_model()
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

# --- install and package ----------------------------------------------------

install(TARGETS HyperDR RUNTIME DESTINATION bin COMPONENT Runtime)

install(DIRECTORY apps/panel/ DESTINATION apps/panel COMPONENT Runtime
  PATTERN "__pycache__" EXCLUDE
  PATTERN "*.pyc" EXCLUDE)
hyperdr_install_model_assets()
# PyTorch checkpoints, optimizer state, virtual environments and private
# training data are intentionally not installed. The inference-only ONNX and
# ncnn files remain offline build assets; the release executable contains the
# fixed ncnn models as aligned byte arrays.
# The panel derives its settings vocabulary from this file, so it ships too.
install(FILES schema/settings.json schema/report.json DESTINATION schema COMPONENT Runtime)
install(FILES LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md DESTINATION . COMPONENT Runtime)
install(FILES packaging/INSTALL.md DESTINATION . RENAME INSTALL.md COMPONENT Runtime)

set(CPACK_PACKAGE_NAME "HyperDR")
set(CPACK_PACKAGE_VENDOR "Renhe Wang")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(HYPERDR_PACKAGE_PLATFORM macos-${CMAKE_SYSTEM_PROCESSOR})
set(CPACK_PACKAGE_FILE_NAME "${PROJECT_NAME}-${PROJECT_VERSION}-${HYPERDR_PACKAGE_PLATFORM}")
set(CPACK_GENERATOR "ZIP")
set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY ON)
include(CPack)

option(HYPERDR_BUILD_FUZZERS "Build opt-in LLVM parser fuzz targets" OFF)
if(HYPERDR_BUILD_FUZZERS)
  add_subdirectory(tests/fuzz)
endif()

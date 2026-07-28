cmake_minimum_required(VERSION 3.25)
project(HyperDR VERSION 0.3.0 LANGUAGES CXX)

if(NOT WIN32 OR NOT MSVC)
  message(FATAL_ERROR "HyperDR requires Windows with MSVC")
endif()

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

option(HYPERDR_WITH_CODECS "Build LibRaw/libheif/libavif/libultrahdr support" ON)
option(HYPERDR_BUILD_TESTS "Build unit tests" ON)
option(HYPERDR_ENABLE_AVX2 "Enable AVX2 code generation for Release builds" OFF)

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

list(APPEND CMAKE_MODULE_PATH ${CMAKE_CURRENT_SOURCE_DIR}/cmake)
include(HyperDRCompiler)
include(HyperDRTesting)
include(HyperDRCodecs)

find_package(Threads REQUIRED)

include(CheckIPOSupported)
check_ipo_supported(RESULT HYPERDR_IPO_SUPPORTED OUTPUT HYPERDR_IPO_ERROR LANGUAGES CXX)

include(CTest)

add_subdirectory(modules/foundation)
add_subdirectory(modules/image)
add_subdirectory(modules/look)
add_subdirectory(modules/container)
add_subdirectory(modules/gainmap)
add_subdirectory(modules/codec)
add_subdirectory(modules/app)

# --- install and package ----------------------------------------------------

install(TARGETS HyperDR RUNTIME DESTINATION bin COMPONENT Runtime)
install(FILES $<TARGET_RUNTIME_DLLS:HyperDR> DESTINATION bin COMPONENT Runtime)
# TARGET_RUNTIME_DLLS covers the executable's direct link dependencies, but
# several codec DLLs load their own vcpkg DLLs (AOM, zlib, JPEG, PNG, libyuv,
# libde265). Ship the release triplet's runtime set so a clean machine does not
# fail before main(). The prepared Main10 x265 pair below is installed last and
# deliberately replaces vcpkg's ordinary 8-bit libx265.dll.
if(HYPERDR_WITH_CODECS AND DEFINED VCPKG_INSTALLED_DIR AND
   DEFINED VCPKG_TARGET_TRIPLET)
  install(DIRECTORY
    "${VCPKG_INSTALLED_DIR}/${VCPKG_TARGET_TRIPLET}/bin/"
    DESTINATION bin COMPONENT Runtime
    FILES_MATCHING PATTERN "*.dll")
endif()
# The dual x265 runtime is prepared after the ordinary vcpkg build. It is not
# represented by HyperDR's link graph: libx265_main.dll is loaded by x265 at
# runtime, and the staged libx265.dll deliberately replaces vcpkg's 8-bit DLL.
# Install the prepared pair last so CPack cannot silently ship an 8-bit-only
# archive that advertises PQ/HLG support.
if(HYPERDR_WITH_CODECS)
  install(FILES
    "${CMAKE_BINARY_DIR}/x265-runtime/$<CONFIG>/libx265.dll"
    "${CMAKE_BINARY_DIR}/x265-runtime/$<CONFIG>/libx265_main.dll"
    DESTINATION bin COMPONENT Runtime)
endif()
include(InstallRequiredSystemLibraries)
if(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
  install(PROGRAMS ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS} DESTINATION bin COMPONENT Runtime)
endif()

install(DIRECTORY apps/panel/ DESTINATION apps/panel COMPONENT Runtime
  PATTERN "__pycache__" EXCLUDE
  PATTERN "*.pyc" EXCLUDE)
# The panel derives its settings vocabulary from this file, so it ships too.
install(FILES schema/settings.json schema/report.json DESTINATION schema COMPONENT Runtime)
install(FILES Start.bat Setup-HTTPS.bat DESTINATION . COMPONENT Runtime)
# Safari's WebGPU HDR canvas needs a real secure context, so the HTTPS setup is
# part of installing HyperDR rather than an optional extra. Both launchers share
# hyperdr_tls.ps1, so it can never be omitted from a package.
install(FILES
  scripts/start_hyperdr_lan.ps1
  scripts/setup_hyperdr_https.ps1
  scripts/hyperdr_tls.ps1
  scripts/configure_hyperdr_firewall.ps1
  DESTINATION scripts COMPONENT Runtime)
install(FILES LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md DESTINATION . COMPONENT Runtime)
install(FILES docs/iphone-lan.md DESTINATION docs COMPONENT Runtime)
install(FILES packaging/INSTALL.md DESTINATION . RENAME INSTALL.md COMPONENT Runtime)

set(CPACK_PACKAGE_NAME "HyperDR")
set(CPACK_PACKAGE_VENDOR "Renhe Wang")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_FILE_NAME "${PROJECT_NAME}-${PROJECT_VERSION}-windows-x64")
set(CPACK_GENERATOR "ZIP")
set(CPACK_INCLUDE_TOPLEVEL_DIRECTORY ON)
include(CPack)

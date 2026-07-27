# Reading and writing image files.
#
# `descriptors.cpp` and `unavailable.cpp` always compile: the first is pure
# naming, the second defines every entry point for the build without codecs, so
# the two configurations share one call graph and differ only in these leaves.
set(HYPERDR_CODEC_SOURCES
  src/descriptors.cpp
  src/unavailable.cpp)

if(HYPERDR_WITH_CODECS)
  list(APPEND HYPERDR_CODEC_SOURCES
    src/avif_encoder.cpp
    src/heif_encoder.cpp
    src/raster_decoder.cpp
    src/raw_decoder.cpp
    src/ultrahdr_decoder.cpp
    src/ultrahdr_encoder.cpp)
endif()

hyperdr_add_module(codec
  SOURCES ${HYPERDR_CODEC_SOURCES}
  DEPENDS HyperDR::gainmap
  PRIVATE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src)

if(HYPERDR_WITH_CODECS)
  hyperdr_fetch_libultrahdr()
  FetchContent_GetProperties(libuhdr SOURCE_DIR LIBUHDR_SOURCE_DIR)
  find_package(libraw CONFIG REQUIRED)
  find_package(libheif CONFIG REQUIRED)
  find_package(lcms2 CONFIG REQUIRED)
  find_package(JPEG REQUIRED)
  find_package(PNG REQUIRED)
  find_package(libavif CONFIG REQUIRED)
  # PRIVATE: nothing above this module includes a codec header, which is the
  # point of the module existing.
  target_link_libraries(hyperdr_codec PRIVATE
    libraw::raw_r heif lcms2::lcms2 JPEG::JPEG PNG::PNG uhdr avif)
  target_include_directories(hyperdr_codec PRIVATE ${LIBUHDR_SOURCE_DIR})
endif()

add_subdirectory(tests)

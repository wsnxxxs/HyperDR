# Reading and writing image files.
#
# `descriptors.cpp` and `unavailable.cpp` always compile: the first is pure
# naming, the second defines every entry point for the build without codecs, so
# the two configurations share one call graph and differ only in these leaves.
set(HYPERDR_CODEC_SOURCES
  src/descriptors.cpp
  src/unavailable.cpp)

if(HYPERDR_WITH_CODECS)
  enable_language(OBJCXX)
  set_source_files_properties(src/raw_ciraw.mm src/gain_map_jpeg_imageio.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
  list(APPEND HYPERDR_CODEC_SOURCES
    src/avif_decoder.cpp
    src/avif_encoder.cpp
    src/heif_encoder.cpp
    src/raster_decoder.cpp
    src/heif_decoder.cpp
    src/tiff_codec.cpp
    src/raw_ciraw.mm
    src/gain_map_jpeg_imageio.mm
    src/gain_map_jpeg_decoder.cpp
    src/gain_map_jpeg_encoder.cpp
    src/hevc/probe.cpp
    src/hevc/quality_map.cpp
    src/hevc/vt_common.cpp
    src/hevc/vt_decoder.cpp
    src/hevc/vt_encoder.cpp
    src/hevc/yuv.cpp
    src/hevc/yuv_to_rgb.cpp)
endif()

hyperdr_add_module(codec
  SOURCES ${HYPERDR_CODEC_SOURCES}
  DEPENDS HyperDR::gainmap
  PRIVATE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src)

if(HYPERDR_WITH_CODECS)
  find_package(libheif CONFIG REQUIRED)
  find_package(lcms2 CONFIG REQUIRED)
  find_package(JPEG REQUIRED)
  find_package(PNG REQUIRED)
  find_package(TIFF REQUIRED)
  find_package(ZLIB REQUIRED)
  find_package(libavif CONFIG REQUIRED)
  # PRIVATE: nothing above this module includes a codec header, which is the
  # point of the module existing.
  target_link_libraries(hyperdr_codec PRIVATE
    heif lcms2::lcms2 JPEG::JPEG PNG::PNG TIFF::TIFF ZLIB::ZLIB avif)
  # HEVC is VideoToolbox's (src/hevc); the frameworks are C APIs.
  target_link_libraries(hyperdr_codec PRIVATE
    "-framework VideoToolbox" "-framework CoreMedia" "-framework CoreVideo"
    "-framework CoreFoundation" "-framework CoreImage" "-framework Foundation"
    "-framework Metal" "-framework ImageIO" "-framework CoreGraphics")
endif()

add_subdirectory(tests)

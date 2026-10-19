# The codec tests encode and decode real files, so they only exist in the
# codec-enabled configuration.
hyperdr_add_test(dcp_reader_test LINK HyperDR::codec)
hyperdr_add_test(lens_profile_test LINK HyperDR::codec)
if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(xmp_look_test LINK HyperDR::codec ZLIB::ZLIB)
  if(TARGET xmp_look_test)
    hyperdr_copy_libultrahdr(xmp_look_test)
  endif()
  hyperdr_add_test(icc_color_test LINK HyperDR::image lcms2::lcms2)
  hyperdr_add_test(png_decode_test LINK HyperDR::codec PNG::PNG lcms2::lcms2)
  hyperdr_add_test(tiff_codec_test LINK HyperDR::codec TIFF::TIFF)
  if(TARGET tiff_codec_test)
    hyperdr_copy_libultrahdr(tiff_codec_test)
  endif()
  if(TARGET png_decode_test)
    hyperdr_copy_libultrahdr(png_decode_test)
  endif()
  # `heif` as well as the module: the test builds its own HEIF fixtures, so it
  # includes <libheif/heif.h> directly, and the module deliberately keeps that
  # dependency private. Without this the only test that exercises the real
  # codec paths fails to compile, which is how it came to be skipped silently.
  hyperdr_add_test(codec_test LINK HyperDR::codec heif avif PNG::PNG lcms2::lcms2)
  hyperdr_add_test(heif_parallel_test LINK HyperDR::codec heif)
  # VideoToolbox HEVC: 77 (skipped) only where no encoder exists at all.
  hyperdr_add_test(hevc_vt_test LINK HyperDR::codec)
  if(TARGET hevc_vt_test)
    target_include_directories(hevc_vt_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    set_tests_properties(hevc_vt_test PROPERTIES SKIP_RETURN_CODE 77)
    hyperdr_copy_libultrahdr(hevc_vt_test)
  endif()
  hyperdr_add_test(alpha_decode_test LINK HyperDR::codec heif avif)
  if(TARGET heif_parallel_test)
    set_tests_properties(heif_parallel_test PROPERTIES SKIP_RETURN_CODE 77)
    hyperdr_copy_libultrahdr(heif_parallel_test)
  endif()
  if(TARGET alpha_decode_test)
    hyperdr_copy_libultrahdr(alpha_decode_test)
  endif()
  if(TARGET codec_test)
    hyperdr_copy_libultrahdr(codec_test)
  endif()

  # Writes its own DNG fixture and decodes it through LibRaw, so it needs the
  # module but none of the container libraries.
  hyperdr_add_test(raw_highlight_test LINK HyperDR::codec)
  hyperdr_add_test(raw_geometry_test LINK HyperDR::image)
  hyperdr_add_test(raw_sensor_geometry_test)

  # Pure boundary tests: no giant fixture or allocation is needed to pin the
  # maximum RAW dimensions and the overflow-safe arithmetic.
  hyperdr_add_test(budget_test LINK HyperDR::foundation)

  # The DNG opcode lists the RAW decoder applies, as bytes and arithmetic.
  hyperdr_add_test(dng_opcode_test)
endif()

if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(gain_map_jpeg_codec_test LINK HyperDR::codec)
  if(TARGET gain_map_jpeg_codec_test)
    # ImageIO reads the files back the way Photos and Preview do.
    target_link_libraries(gain_map_jpeg_codec_test PRIVATE
      "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation")
    hyperdr_copy_libultrahdr(gain_map_jpeg_codec_test)
  endif()
  add_test(NAME gain_map_jpeg_panorama_test COMMAND gain_map_jpeg_codec_test panorama ${CMAKE_BINARY_DIR}/gain-map-panorama.jpg)
  set_tests_properties(gain_map_jpeg_panorama_test PROPERTIES TIMEOUT 180 RUN_SERIAL TRUE)
endif()

if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(gain_map_jpeg_imageio_test LINK HyperDR::codec)
  if(TARGET gain_map_jpeg_imageio_test)
    target_link_libraries(gain_map_jpeg_imageio_test PRIVATE "-framework ImageIO" "-framework CoreFoundation")
    target_compile_definitions(gain_map_jpeg_imageio_test PRIVATE HYPERDR_TEST_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/gain-map-jpeg")
    target_include_directories(gain_map_jpeg_imageio_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    hyperdr_copy_libultrahdr(gain_map_jpeg_imageio_test)
  endif()
  hyperdr_add_test(gain_map_jpeg_decode_test LINK HyperDR::codec uhdr JPEG::JPEG)
  if(TARGET gain_map_jpeg_decode_test)
    target_link_libraries(gain_map_jpeg_decode_test PRIVATE "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation")
    target_compile_definitions(gain_map_jpeg_decode_test PRIVATE HYPERDR_TEST_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/gain-map-jpeg")
    target_include_directories(gain_map_jpeg_decode_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src ${LIBUHDR_SOURCE_DIR})
    hyperdr_copy_libultrahdr(gain_map_jpeg_decode_test)
  endif()
endif()

if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(raw_ciraw_test LINK HyperDR::app)
  if(TARGET raw_ciraw_test)
    target_compile_definitions(raw_ciraw_test PRIVATE HYPERDR_SOURCE_DIR="${PROJECT_SOURCE_DIR}")
    hyperdr_copy_libultrahdr(raw_ciraw_test)
  endif()
endif()

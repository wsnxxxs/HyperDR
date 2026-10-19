# The codec tests encode and decode real files, so they only exist in the
# codec-enabled configuration.
if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(icc_color_test LINK HyperDR::image lcms2::lcms2)
  hyperdr_add_test(png_decode_test LINK HyperDR::codec PNG::PNG lcms2::lcms2)
  hyperdr_add_test(tiff_codec_test LINK HyperDR::codec TIFF::TIFF)
  # `heif` as well as the module: the test builds its own HEIF fixtures, so it
  # includes <libheif/heif.h> directly, and the module deliberately keeps that
  # dependency private. Without this the only test that exercises the real
  # codec paths fails to compile, which is how it came to be skipped silently.
  hyperdr_add_test(codec_test LINK HyperDR::codec heif avif PNG::PNG lcms2::lcms2)
  if(TARGET codec_test)
    target_include_directories(codec_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src ${PROJECT_SOURCE_DIR}/modules/container/src)
  endif()
  hyperdr_add_test(heif_parallel_test LINK HyperDR::codec heif)
  if(TARGET heif_parallel_test)
    add_test(NAME hevc_probe_policy_test COMMAND heif_parallel_test --probe-policy-test)
    target_include_directories(heif_parallel_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  endif()
  # VideoToolbox HEVC: 77 (skipped) only where no encoder exists at all.
  hyperdr_add_test(hevc_vt_test LINK HyperDR::codec)
  if(TARGET hevc_vt_test)
    target_include_directories(hevc_vt_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    set_tests_properties(hevc_vt_test PROPERTIES SKIP_RETURN_CODE 77)
  endif()
  hyperdr_add_test(alpha_decode_test LINK HyperDR::codec heif avif)
  if(TARGET heif_parallel_test)
    set_tests_properties(heif_parallel_test PROPERTIES SKIP_RETURN_CODE 77
      ENVIRONMENT "DYLD_INSERT_LIBRARIES=$<TARGET_FILE:capi_test_clock>")
  endif()


  # Pure boundary tests: no giant fixture or allocation is needed to pin the
  # maximum RAW dimensions and the overflow-safe arithmetic.
  hyperdr_add_test(budget_test LINK HyperDR::foundation)

endif()

if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(gain_map_jpeg_codec_test LINK HyperDR::codec)
  if(TARGET gain_map_jpeg_codec_test)
    # ImageIO reads the files back the way Photos and Preview do.
    target_link_libraries(gain_map_jpeg_codec_test PRIVATE
      "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation")
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
  endif()
  hyperdr_add_test(gain_map_jpeg_decode_test LINK HyperDR::codec JPEG::JPEG)
  if(TARGET gain_map_jpeg_decode_test)
    target_link_libraries(gain_map_jpeg_decode_test PRIVATE "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation")
    target_compile_definitions(gain_map_jpeg_decode_test PRIVATE HYPERDR_TEST_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/gain-map-jpeg")
    target_include_directories(gain_map_jpeg_decode_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  endif()
endif()

if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(raw_ciraw_test LINK HyperDR::app)
  if(TARGET raw_ciraw_test)
    target_compile_definitions(raw_ciraw_test PRIVATE HYPERDR_SOURCE_DIR="${PROJECT_SOURCE_DIR}")
  endif()
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  add_executable(heif_imageio_fixtures heif_imageio_fixtures.cpp)
  target_link_libraries(heif_imageio_fixtures PRIVATE HyperDR::codec heif lcms2::lcms2)
  target_include_directories(heif_imageio_fixtures PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  hyperdr_configure_target(heif_imageio_fixtures)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_test(NAME heif_writer_imageio_test COMMAND ${Python3_EXECUTABLE}
    ${PROJECT_SOURCE_DIR}/tests/hevc/check_imageio.py
    --writer-fixtures $<TARGET_FILE:heif_imageio_fixtures> --build-dir ${CMAKE_BINARY_DIR}/heif-imageio)
  set_tests_properties(heif_writer_imageio_test PROPERTIES TIMEOUT 180 RUN_SERIAL TRUE)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  add_executable(heif_imageio_renditions heif_imageio_renditions.cpp)
  target_link_libraries(heif_imageio_renditions PRIVATE HyperDR::codec)
  target_include_directories(heif_imageio_renditions PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  hyperdr_configure_target(heif_imageio_renditions)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  add_test(NAME heif_export_imageio_test COMMAND ${Python3_EXECUTABLE}
    ${PROJECT_SOURCE_DIR}/tests/hevc/check_imageio.py $<TARGET_FILE:HyperDR>
    --rendition-fixtures $<TARGET_FILE:heif_imageio_renditions> --build-dir ${CMAKE_BINARY_DIR}/heif-imageio)
  set_tests_properties(heif_export_imageio_test PROPERTIES TIMEOUT 300 RUN_SERIAL TRUE)
endif()

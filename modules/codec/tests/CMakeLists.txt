# The codec tests encode and decode real files, so they only exist in the
# codec-enabled configuration.
if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(icc_color_test LINK HyperDR::image lcms2::lcms2)
  hyperdr_add_test(png_decode_test LINK HyperDR::codec PNG::PNG lcms2::lcms2)
  hyperdr_add_test(tiff_codec_test LINK HyperDR::codec TIFF::TIFF)
  hyperdr_add_test(codec_test LINK HyperDR::codec avif PNG::PNG lcms2::lcms2)
  if(TARGET codec_test)
    target_include_directories(codec_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src ${PROJECT_SOURCE_DIR}/modules/container/src)
  endif()
  hyperdr_add_test(heif_parallel_test LINK HyperDR::codec)
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
  hyperdr_add_test(hevc_vt_decode_test LINK HyperDR::codec)
  if(TARGET hevc_vt_decode_test)
    target_sources(hevc_vt_decode_test PRIVATE hevc_decode_fixture.cpp)
    target_compile_definitions(hevc_vt_decode_test PRIVATE
      HYPERDR_HEVC_DECODE_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/hevc_decode")
    target_include_directories(hevc_vt_decode_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    add_test(NAME hevc_vt_decode_memory_test COMMAND hevc_vt_decode_test memory)
    set_tests_properties(hevc_vt_decode_test hevc_vt_decode_memory_test PROPERTIES RUN_SERIAL TRUE TIMEOUT 180)
  endif()
  hyperdr_add_test(alpha_decode_test LINK HyperDR::codec avif)
  if(TARGET alpha_decode_test)
    target_include_directories(alpha_decode_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src ${PROJECT_SOURCE_DIR}/modules/container/src)
  endif()
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
  # E8: AVIF grid output, decoded by libavif and by ImageIO.
  hyperdr_add_test(avif_grid_test LINK HyperDR::codec avif)
  if(TARGET avif_grid_test)
    target_link_libraries(avif_grid_test PRIVATE "-framework ImageIO" "-framework CoreGraphics" "-framework CoreFoundation")
    target_include_directories(avif_grid_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  endif()
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
  target_link_libraries(heif_imageio_fixtures PRIVATE HyperDR::codec lcms2::lcms2)
  target_include_directories(heif_imageio_fixtures PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  hyperdr_configure_target(heif_imageio_fixtures)
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  add_test(NAME heif_writer_imageio_test COMMAND ${Python3_EXECUTABLE}
    ${PROJECT_SOURCE_DIR}/tests/hevc/check_imageio.py
    --writer-fixtures $<TARGET_FILE:heif_imageio_fixtures> --build-dir ${CMAKE_BINARY_DIR}/heif-imageio)
  set_tests_properties(heif_writer_imageio_test PROPERTIES TIMEOUT 180 RUN_SERIAL TRUE)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  # Same real TIFF test, deliberately throwing after its first fixture write.
  add_executable(tiff_codec_failure_test tiff_codec_test.cpp)
  target_link_libraries(tiff_codec_failure_test PRIVATE HyperDR::codec TIFF::TIFF)
  target_compile_definitions(tiff_codec_failure_test PRIVATE HYPERDR_TEST_INJECT_FAILURE=1)
  hyperdr_configure_target(tiff_codec_failure_test)
  add_test(NAME native_temp_isolation_test COMMAND ${Python3_EXECUTABLE}
    ${PROJECT_SOURCE_DIR}/tests/support/check_concurrent_temp.py
    $<TARGET_FILE:png_decode_test> $<TARGET_FILE:tiff_codec_test>
    $<TARGET_FILE:hash_test> $<TARGET_FILE:file_io_test>
    --failure $<TARGET_FILE:tiff_codec_failure_test>)
  set_tests_properties(native_temp_isolation_test PROPERTIES TIMEOUT 180)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  # Deliberately replaces only the YUV conversion object in this executable.
  # The codec library carries the product's copy of the same symbols; the link
  # keeps the executable's definition because the library's member is never
  # pulled in, and `heif_input_probe --self-test` fails if that stops being so.
  add_executable(heif_input_probe EXCLUDE_FROM_ALL
    heif_input_probe.cpp ../src/hevc/yuv_to_rgb.cpp)
  target_compile_definitions(heif_input_probe PRIVATE HYPERDR_HEIF_CHROMA_DIAGNOSTIC=1)
  target_include_directories(heif_input_probe PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  target_link_libraries(heif_input_probe PRIVATE HyperDR::codec)
  hyperdr_configure_target(heif_input_probe)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  # Reads headerless oriented linear-P3 float dumps; no decoder dependency.
  add_executable(heif_input_metrics EXCLUDE_FROM_ALL heif_input_metrics.cpp)
  target_link_libraries(heif_input_metrics PRIVATE HyperDR::image HyperDR::foundation)
  hyperdr_configure_target(heif_input_metrics)
endif()

if(HYPERDR_WITH_CODECS)
  # Verification rejections and whole-canvas diagnostics.
  hyperdr_add_test(heic_verify_test LINK HyperDR::codec lcms2::lcms2)
  if(TARGET heic_verify_test)
    target_include_directories(heic_verify_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    set_tests_properties(heic_verify_test PROPERTIES TIMEOUT 300)
  endif()
  hyperdr_add_test(heif_input_test LINK HyperDR::codec lcms2::lcms2)
  if(TARGET heif_input_test)
    target_include_directories(heif_input_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    # ImageIO is the independent reference for imir/irot orientation.
    target_link_libraries(heif_input_test PRIVATE
      "-framework ImageIO" "-framework CoreFoundation")
    set_tests_properties(heif_input_test PROPERTIES TIMEOUT 300)
  endif()
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  add_executable(quality_lab EXCLUDE_FROM_ALL ${PROJECT_SOURCE_DIR}/tests/quality/quality_lab.mm)
  target_include_directories(quality_lab PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
  target_link_libraries(quality_lab PRIVATE HyperDR::app lcms2::lcms2)
  target_compile_options(quality_lab PRIVATE -fobjc-arc)
  hyperdr_configure_target(quality_lab)
  add_library(quality_vt_trace SHARED EXCLUDE_FROM_ALL ${PROJECT_SOURCE_DIR}/tests/quality/vt_trace.mm)
  target_link_libraries(quality_vt_trace PRIVATE "-framework VideoToolbox" "-framework CoreFoundation")
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  add_executable(e5_package_quality EXCLUDE_FROM_ALL ${PROJECT_SOURCE_DIR}/tests/quality/e5_package.cpp)
  target_link_libraries(e5_package_quality PRIVATE HyperDR::app)
  hyperdr_configure_target(e5_package_quality)
endif()

if(HYPERDR_WITH_CODECS AND HYPERDR_BUILD_TESTS)
  hyperdr_add_test(metal_yuv_test SOURCES metal_yuv_test.mm LINK HyperDR::codec)
  if(TARGET metal_yuv_test)
    target_include_directories(metal_yuv_test PRIVATE ${PROJECT_SOURCE_DIR}/modules/codec/src)
    target_compile_options(metal_yuv_test PRIVATE -fobjc-arc)
    set_tests_properties(metal_yuv_test PROPERTIES SKIP_RETURN_CODE 77)
  endif()
endif()

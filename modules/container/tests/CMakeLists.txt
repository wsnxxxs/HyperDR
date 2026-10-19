hyperdr_add_test(exif_test LINK HyperDR::container)
hyperdr_add_test(inspect_test LINK HyperDR::container)
hyperdr_add_test(iso_gain_map_test LINK HyperDR::container)
hyperdr_add_test(heif_writer_test LINK HyperDR::container)
if(TARGET heif_writer_test)
  target_include_directories(heif_writer_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
  target_compile_definitions(heif_writer_test PRIVATE HYPERDR_HEIF_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/heif_writer")
  set_tests_properties(heif_writer_test PROPERTIES TIMEOUT 60)
endif()
if(HYPERDR_WITH_CODECS)
  # The goldens' VPS/SPS/PPS come from the VideoToolbox adapter (codec/src).
  hyperdr_add_test(heif_writer_items_test LINK HyperDR::container)
  if(TARGET heif_writer_items_test)
    target_compile_definitions(heif_writer_items_test PRIVATE HYPERDR_HEIF_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/heif_writer")
    set_tests_properties(heif_writer_items_test PROPERTIES TIMEOUT 60)
  endif()
endif()

hyperdr_add_test(gain_map_jpeg_test LINK HyperDR::container)
if(TARGET gain_map_jpeg_test)
  target_compile_definitions(gain_map_jpeg_test PRIVATE HYPERDR_JPEG_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/gain_map_jpeg")
endif()

hyperdr_add_test(heif_reader_test LINK HyperDR::container)
if(TARGET heif_reader_test)
  target_compile_definitions(heif_reader_test PRIVATE
    HYPERDR_HEIF_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/heif_writer"
    HYPERDR_SOURCE_ROOT="${PROJECT_SOURCE_DIR}"
    HYPERDR_READER_GOLDENS="${CMAKE_CURRENT_SOURCE_DIR}/fixtures/heif_reader")
endif()
hyperdr_add_test(heif_malformed_test LINK HyperDR::container)
if(TARGET heif_malformed_test)
  target_compile_definitions(heif_malformed_test PRIVATE
    HYPERDR_MALFORMED_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/heif_malformed")
endif()
hyperdr_add_test(heif_reader_limits_test LINK HyperDR::container)
if(TARGET heif_reader_limits_test)
  target_include_directories(heif_reader_limits_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../src)
  target_compile_definitions(heif_reader_limits_test PRIVATE
    HYPERDR_MALFORMED_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/heif_malformed")
  set_tests_properties(heif_reader_limits_test PROPERTIES TIMEOUT 60)
endif()

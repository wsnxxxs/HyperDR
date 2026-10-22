hyperdr_add_test(hash_test LINK HyperDR::foundation)
if(TARGET hash_test)
  # The RAW sample comes from scripts/fetch_test_fixtures.py, as for tests/capi.
  target_compile_definitions(hash_test PRIVATE
    HYPERDR_HASH_JPEG="${PROJECT_SOURCE_DIR}/apps/apple/HyperDRPreviewTests/Fixtures/photo.jpg"
    HYPERDR_HASH_ARW="${PROJECT_SOURCE_DIR}/build/fixtures/sony-ilce-7s.ARW")
endif()
hyperdr_add_test(json_test LINK HyperDR::foundation)
hyperdr_add_test(json_writer_test LINK HyperDR::foundation)
hyperdr_add_test(file_io_test LINK HyperDR::foundation)

hyperdr_add_test(cancel_test LINK HyperDR::foundation)

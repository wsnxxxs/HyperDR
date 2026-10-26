foreach(linkage shared static)
  add_executable(capi_${linkage}_test lifecycle.c)
  set_target_properties(capi_${linkage}_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  if(linkage STREQUAL "shared")
    target_link_libraries(capi_${linkage}_test PRIVATE HyperDR::capi)
  else()
    target_link_libraries(capi_${linkage}_test PRIVATE HyperDR::capi_static)
  endif()
  add_test(NAME capi_${linkage}_test COMMAND capi_${linkage}_test)
endforeach()
if(HYPERDR_WITH_CODECS)
  # The packaging entry point writes real files, so it needs the encoder paths.
  # Synthetic planes keep it independent of the RAW and HEIC fixtures.
  find_package(libavif CONFIG REQUIRED)
  add_executable(capi_package_rows_test package_rows_test.cpp)
  target_link_libraries(capi_package_rows_test PRIVATE HyperDR::capi_static HyperDR::app avif)
  set_target_properties(capi_package_rows_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  add_test(NAME capi_package_rows_test COMMAND capi_package_rows_test)
  find_package(TIFF REQUIRED)
  add_executable(capi_package_lossless_test package_lossless_test.cpp)
  target_link_libraries(capi_package_lossless_test PRIVATE HyperDR::capi_static HyperDR::app TIFF::TIFF)
  set_target_properties(capi_package_lossless_test PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  add_test(NAME capi_package_lossless_test COMMAND capi_package_lossless_test)
  add_executable(capi_package_test package_test.c)
  set_target_properties(capi_package_test PROPERTIES
    C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  target_link_libraries(capi_package_test PRIVATE HyperDR::capi_static)
  add_test(NAME capi_package_test COMMAND capi_package_test)
endif()
if(APPLE)
  add_library(capi_test_clock SHARED frozen_time.c)
  set_target_properties(capi_test_clock PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  if(HYPERDR_WITH_CODECS)
    set_tests_properties(capi_package_rows_test PROPERTIES
      ENVIRONMENT "DYLD_INSERT_LIBRARIES=$<TARGET_FILE:capi_test_clock>")
    # G19: exercise every decoding entry on a GCD-sized worker stack.
    # Run every entry point on a 512 KiB pthread before the main thread initializes
    # lazy static tables, then require byte-identical results.
    # AVIF PQ carries no LittleCMS creation timestamp, so worker/main export
    # bytes are deterministic without a clock interposer or test environment.
    add_executable(capi_small_stack_test small_stack.c)
    set_target_properties(capi_small_stack_test PROPERTIES
      C_STANDARD 11 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF
      RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
    target_compile_definitions(capi_small_stack_test PRIVATE HYPERDR_GAIN_FIXTURES="${PROJECT_SOURCE_DIR}/tests/fixtures/gain-map-jpeg")
    target_link_libraries(capi_small_stack_test PRIVATE HyperDR::capi HyperDR::app Threads::Threads)
    add_test(NAME capi_small_stack_test COMMAND capi_small_stack_test
      ${PROJECT_SOURCE_DIR}/build/fixtures/sony-ilce-7s.ARW
      ${PROJECT_SOURCE_DIR}/tests/macos_t2/fixtures/gamma-1-control.heic)
    set_tests_properties(capi_small_stack_test PROPERTIES TIMEOUT 180
      ENVIRONMENT "DYLD_INSERT_LIBRARIES=$<TARGET_FILE:capi_test_clock>")
    enable_language(OBJCXX)
    add_executable(capi_raw_compat_test raw_compat_test.mm)
    target_link_libraries(capi_raw_compat_test PRIVATE HyperDR::capi_static
      "-framework CoreImage" "-framework Foundation" "-framework ImageIO")
    target_compile_definitions(capi_raw_compat_test PRIVATE HYPERDR_SOURCE_DIR="${PROJECT_SOURCE_DIR}")
    target_compile_options(capi_raw_compat_test PRIVATE -fobjc-arc)
    hyperdr_configure_target(capi_raw_compat_test)
    add_test(NAME capi_raw_compat_test COMMAND capi_raw_compat_test)
    set_tests_properties(capi_raw_compat_test PROPERTIES TIMEOUT 180)
  endif()
endif()
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_FOUND)
  # Homebrew's launcher reexecutes Python.app; preload sanitizers/test clock into
  # the interpreter itself. Other Python distributions use sys.executable.
  execute_process(COMMAND ${Python3_EXECUTABLE} -c
    "import pathlib,sys; p=pathlib.Path(sys.base_prefix)/'Resources/Python.app/Contents/MacOS/Python'; print(p if p.is_file() else sys.executable)"
    OUTPUT_VARIABLE HYPERDR_CONTRACT_PYTHON OUTPUT_STRIP_TRAILING_WHITESPACE)

endif()

if(Python3_FOUND AND HYPERDR_WITH_CODECS AND APPLE)
  add_test(NAME capi_verify_memory_test COMMAND ${HYPERDR_CONTRACT_PYTHON}
    ${CMAKE_CURRENT_SOURCE_DIR}/verify_memory_test.py $<TARGET_FILE:capi_package_rows_test>)
  set_tests_properties(capi_verify_memory_test PROPERTIES TIMEOUT 240 RUN_SERIAL TRUE)
endif()

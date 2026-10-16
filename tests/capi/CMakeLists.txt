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
if(APPLE)
  add_library(capi_test_clock SHARED frozen_time.c)
  set_target_properties(capi_test_clock PROPERTIES LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
endif()
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_FOUND)
  # Homebrew's launcher reexecutes Python.app; preload sanitizers/test clock into
  # the interpreter itself. Other Python distributions use sys.executable.
  execute_process(COMMAND ${Python3_EXECUTABLE} -c
    "import pathlib,sys; p=pathlib.Path(sys.base_prefix)/'Resources/Python.app/Contents/MacOS/Python'; print(p if p.is_file() else sys.executable)"
    OUTPUT_VARIABLE HYPERDR_CONTRACT_PYTHON OUTPUT_STRIP_TRAILING_WHITESPACE)
  add_test(NAME capi_contract_test COMMAND ${HYPERDR_CONTRACT_PYTHON}
    ${CMAKE_CURRENT_SOURCE_DIR}/contract_test.py
    $<TARGET_FILE:HyperDR> $<TARGET_FILE:hyperdr_capi>)
  if(APPLE)
    set_tests_properties(capi_contract_test PROPERTIES ENVIRONMENT
      "DYLD_INSERT_LIBRARIES=$<TARGET_FILE:capi_test_clock>")
  endif()
endif()

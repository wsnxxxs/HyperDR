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
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_FOUND)
  add_test(NAME capi_contract_test COMMAND ${Python3_EXECUTABLE}
    ${CMAKE_CURRENT_SOURCE_DIR}/contract_test.py
    $<TARGET_FILE:HyperDR> $<TARGET_FILE:hyperdr_capi>)
endif()

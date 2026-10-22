# The C ABI sits above app and includes only its public interfaces.
add_library(hyperdr_capi SHARED src/capi.cpp)
add_library(hyperdr_capi_static STATIC src/capi.cpp)
add_library(HyperDR::capi ALIAS hyperdr_capi)
add_library(HyperDR::capi_static ALIAS hyperdr_capi_static)
foreach(target hyperdr_capi hyperdr_capi_static)
  target_include_directories(${target} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
  target_link_libraries(${target} PRIVATE HyperDR::app)
  hyperdr_configure_target(${target})
  set_target_properties(${target} PROPERTIES OUTPUT_NAME hyperdr
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
endforeach()
target_compile_definitions(hyperdr_capi PUBLIC HYPERDR_SHARED PRIVATE HYPERDR_CAPI_BUILD)
if(APPLE)
  target_link_options(hyperdr_capi PRIVATE
    "LINKER:-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exports.macos")
  set_property(TARGET hyperdr_capi APPEND PROPERTY LINK_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/exports.macos)
else()
  target_link_options(hyperdr_capi PRIVATE
    "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/exports.map")
  set_property(TARGET hyperdr_capi APPEND PROPERTY LINK_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/exports.map)
endif()

if(HYPERDR_BUILD_TESTS)
  enable_language(C)
  add_subdirectory(${PROJECT_SOURCE_DIR}/tests/capi ${CMAKE_CURRENT_BINARY_DIR}/tests)
endif()

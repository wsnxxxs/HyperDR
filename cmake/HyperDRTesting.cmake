# One test executable per source file, registered with CTest.
#
# The tests are plain programs that throw on failure: no framework to install,
# and each one links only the module it exercises, so a test that reaches across
# a layer boundary fails to link rather than passing quietly.

function(hyperdr_add_test name)
  cmake_parse_arguments(TEST "" "" "SOURCES;LINK" ${ARGN})
  if(NOT HYPERDR_BUILD_TESTS)
    return()
  endif()
  if(NOT TEST_SOURCES)
    set(TEST_SOURCES ${name}.cpp)
  endif()
  add_executable(${name} ${TEST_SOURCES})
  target_link_libraries(${name} PRIVATE ${TEST_LINK})
  hyperdr_configure_target(${name})
  add_test(NAME ${name} COMMAND ${name})
endfunction()

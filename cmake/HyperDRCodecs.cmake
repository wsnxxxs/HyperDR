# The image codecs, and the Windows runtime juggling they require.
#
# Everything here is conditional on HYPERDR_WITH_CODECS. The dependency-free
# core build carries the whole renderer and its test suite, so this file is the
# only place that needs a package manager at all.

include(FetchContent)

# Google libultrahdr is the reference JPEG/R implementation. Pin the release so
# output structure and metadata do not change underneath reproducible builds.
FetchContent_Declare(libuhdr
  GIT_REPOSITORY https://github.com/google/libultrahdr.git
  GIT_TAG d52a0d13814ca399fc8a07e23de1d2c63f0e8404 # v1.4.0
)

function(hyperdr_fetch_libultrahdr)
  set(BUILD_SHARED_LIBS ON)
  set(UHDR_BUILD_EXAMPLES OFF)
  set(UHDR_BUILD_TESTS OFF)
  set(UHDR_BUILD_BENCHMARK OFF)
  set(UHDR_BUILD_FUZZERS OFF)
  set(UHDR_BUILD_DEPS OFF)
  set(UHDR_BUILD_JAVA OFF)
  set(UHDR_BUILD_PACKAGING OFF)
  set(UHDR_ENABLE_INSTALL OFF)
  set(UHDR_ENABLE_GLES OFF)
  # Keep a finite allocation guard, but allow current high-resolution cameras
  # whose full-width output exceeds libultrahdr's conservative 8192 default.
  set(UHDR_MAX_DIMENSION 12800)
  # Android recommends carrying both packets for maximum compatibility.
  set(UHDR_WRITE_XMP ON)
  set(UHDR_WRITE_ISO ON)
  FetchContent_MakeAvailable(libuhdr)
endfunction()

# x265 ships as a single-bit-depth DLL per configuration, and PQ/HLG need
# Main10. The helper script prepares a dual 8/10-bit runtime once; this hook
# restores it after every rebuild, which would otherwise overwrite it.
function(hyperdr_restore_x265_multibit target)
  if(HYPERDR_WITH_CODECS)
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND powershell -NoProfile -ExecutionPolicy Bypass -File
              "${PROJECT_SOURCE_DIR}/scripts/restore_x265_multibit.ps1"
              -BuildDirectory "${CMAKE_BINARY_DIR}" -Configuration "$<CONFIG>"
      VERBATIM)
  endif()
endfunction()

# libultrahdr is built as a shared library, so consumers need it beside them.
function(hyperdr_copy_libultrahdr target)
  if(HYPERDR_WITH_CODECS AND TARGET uhdr)
    add_custom_command(TARGET ${target} POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              $<TARGET_FILE:uhdr> $<TARGET_FILE_DIR:${target}>
      VERBATIM)
  endif()
endfunction()

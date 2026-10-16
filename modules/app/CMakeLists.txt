# The command-line application: settings, discovery, resumable batches,
# reporting, and the run loop.
hyperdr_add_module(app
  SOURCES
    src/analysis_cache.cpp
    src/batch.cpp
    src/cli.cpp
    src/cli_preview.cpp
    src/cli_model.cpp
    src/cli_binary.cpp
    src/cli_inspection.cpp
    src/cli_conversion.cpp
    src/cli_parameters.cpp
    src/decode_cache.cpp
    src/discovery.cpp
    src/fingerprint.cpp
    src/preview.cpp
    src/report.cpp
    src/resume_state.cpp
    src/schema.cpp
    src/settings.cpp
  DEPENDS HyperDR::codec)

add_executable(HyperDR src/main.cpp)
target_link_libraries(HyperDR PRIVATE HyperDR::app)
hyperdr_configure_target(HyperDR)
hyperdr_restore_x265_multibit(HyperDR)
hyperdr_copy_libultrahdr(HyperDR)
if(HYPERDR_OPENMP_RUNTIME_DLL)
  # The Tauri sidecar embeds the DLLs staged beside HyperDR.exe.
  add_custom_command(TARGET HyperDR POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${HYPERDR_OPENMP_RUNTIME_DLL}" "$<TARGET_FILE_DIR:HyperDR>"
    VERBATIM)
endif()

add_subdirectory(tests)

# The command-line application: settings, discovery, resumable batches,
# reporting, and the run loop.
hyperdr_add_module(app
  SOURCES
    src/analysis_cache.cpp
    src/engine.cpp
    src/engine_preview.cpp
    src/engine_model.cpp
    src/edit_options.cpp
    src/batch.cpp
    src/export_memory.cpp
    src/package.cpp
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

# The iOS slices are a library for the app: a command-line executable cannot be
# built for iOS, and the engine reaches iOS only through the C ABI.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  add_executable(HyperDR src/main.cpp)
  target_link_libraries(HyperDR PRIVATE HyperDR::app)
  hyperdr_configure_target(HyperDR)
endif()

add_subdirectory(tests)

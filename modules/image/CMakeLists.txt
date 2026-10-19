# The float image container, colour primaries, transfer functions, resampling,
# and the presentation frame placed around an export.
hyperdr_add_module(image
  SOURCES
    src/fidelity.cpp
    src/frame.cpp
    src/orientation.cpp
    src/resample.cpp
    src/transfer.cpp
  DEPENDS HyperDR::foundation)

add_subdirectory(tests)

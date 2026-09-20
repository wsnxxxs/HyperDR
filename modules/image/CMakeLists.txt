# The float image container, colour primaries, transfer functions, resampling.
hyperdr_add_module(image
  SOURCES
    src/dng_color.cpp
    src/fidelity.cpp
    src/orientation.cpp
    src/resample.cpp
    src/transfer.cpp
  DEPENDS HyperDR::foundation)

add_subdirectory(tests)

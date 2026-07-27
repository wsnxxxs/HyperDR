# Turning a linear image into an SDR base plus a gain map, and back again.
hyperdr_add_module(gainmap
  SOURCES
    src/coding.cpp
    src/gain_map.cpp
    src/neutral.cpp
    src/photographic.cpp
    src/reconstruct.cpp
    src/render.cpp
  DEPENDS HyperDR::look HyperDR::container)

add_subdirectory(tests)

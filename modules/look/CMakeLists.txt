hyperdr_add_module(look
  SOURCES src/grid.cpp src/options.cpp src/rendition.cpp
  DEPENDS HyperDR::image)
add_subdirectory(tests)

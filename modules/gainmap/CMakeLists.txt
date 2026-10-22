hyperdr_add_module(gainmap
  SOURCES src/coding.cpp src/reconstruct.cpp
  DEPENDS HyperDR::look HyperDR::container)
add_subdirectory(tests)

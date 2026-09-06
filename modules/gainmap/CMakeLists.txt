# Turning a linear image into an SDR base plus a gain map, and back again.
hyperdr_add_module(gainmap
  SOURCES
    src/coding.cpp
    src/display_referred.cpp
    src/external.cpp
    src/gain_map.cpp
    src/native_model.cpp
    src/photographic.cpp
    src/reconstruct.cpp
    src/render.cpp
  DEPENDS HyperDR::look HyperDR::container)

if(HYPERDR_WITH_NCNN)
  target_sources(hyperdr_gainmap PRIVATE src/ncnn_runtime.cpp)
  target_link_libraries(hyperdr_gainmap PRIVATE ${HYPERDR_NCNN_TARGET})
endif()

add_subdirectory(tests)

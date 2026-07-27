# Rendering intent: the tone curve, scene analysis, exposure and headroom
# selection, and the filters the local gain is built with. Knows nothing about
# gain maps, containers or codecs.
hyperdr_add_module(look
  SOURCES
    src/curve.cpp
    src/exposure.cpp
    src/filter.cpp
    src/grid.cpp
    src/headroom.cpp
    src/options.cpp
    src/scene_stats.cpp
    src/tone_curve.cpp
  DEPENDS HyperDR::image)

add_subdirectory(tests)

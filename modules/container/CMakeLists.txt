# On-disk metadata formats: the HEIF box tree, ISO 21496-1 gain-map metadata,
# and Exif/XMP. No codec is involved: everything here is byte-level.
hyperdr_add_module(container
  SOURCES
    src/exif.cpp
    src/heif_tmap.cpp
    src/inspect.cpp
    src/iso_gain_map.cpp
  DEPENDS HyperDR::foundation
  PRIVATE_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/src)

add_subdirectory(tests)

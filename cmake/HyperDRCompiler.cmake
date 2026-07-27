# Compiler settings applied identically to every HyperDR target.
#
# These used to be repeated per target -- fifteen copies of the same
# /W4 /permissive- /utf-8 block, several of which had drifted -- so a new test
# executable silently opted out of warnings by being written without them.

function(hyperdr_configure_target target)
  target_compile_features(${target} PUBLIC cxx_std_20)
  set_target_properties(${target} PROPERTIES CXX_EXTENSIONS OFF)
  # NOMINMAX and WIN32_LEAN_AND_MEAN are public: any consumer that includes
  # <windows.h> after our headers needs the same view of it.
  target_compile_definitions(${target} PUBLIC NOMINMAX WIN32_LEAN_AND_MEAN)
  target_compile_definitions(${target}
    PUBLIC HYPERDR_WITH_CODECS=$<IF:$<BOOL:${HYPERDR_WITH_CODECS}>,1,0>)
  target_compile_options(${target} PRIVATE /W4 /permissive- /utf-8)
  target_compile_options(${target} PRIVATE
    $<$<AND:$<CONFIG:Release>,$<BOOL:${HYPERDR_ENABLE_AVX2}>>:/arch:AVX2>)
  # Every executable lands at the top of the build tree, where the Windows
  # runtime DLLs (libheif, libx265's dual 8/10-bit pair, libultrahdr) are staged.
  # Scattering them across module subdirectories would mean staging those DLLs
  # once per directory.
  get_target_property(hyperdr_target_type ${target} TYPE)
  if(hyperdr_target_type STREQUAL "EXECUTABLE")
    set_target_properties(${target} PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
  endif()
  if(HYPERDR_IPO_SUPPORTED)
    set_property(TARGET ${target} PROPERTY INTERPROCEDURAL_OPTIMIZATION_RELEASE ON)
  endif()
endfunction()

# One module: a static library whose public headers live in its own include/
# root. The include root is what enforces the layering -- a module can only
# include headers from modules it links, so an upward dependency fails to
# compile instead of merely being impolite.
function(hyperdr_add_module name)
  cmake_parse_arguments(MODULE "" "" "SOURCES;DEPENDS;PRIVATE_INCLUDE" ${ARGN})
  add_library(hyperdr_${name} STATIC ${MODULE_SOURCES})
  add_library(HyperDR::${name} ALIAS hyperdr_${name})
  target_include_directories(hyperdr_${name}
    PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
  if(MODULE_PRIVATE_INCLUDE)
    target_include_directories(hyperdr_${name} PRIVATE ${MODULE_PRIVATE_INCLUDE})
  endif()
  if(MODULE_DEPENDS)
    target_link_libraries(hyperdr_${name} PUBLIC ${MODULE_DEPENDS})
  endif()
  hyperdr_configure_target(hyperdr_${name})
endfunction()

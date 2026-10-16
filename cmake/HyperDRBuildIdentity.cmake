# The identity belongs to the library, independent of its host executable.
# Include sources/assets and the pinned dependency manifest, not filesystem
# paths or configure time, so CLI and static/shared C ABI agree in one build.
file(GLOB_RECURSE hyperdr_identity_inputs CONFIGURE_DEPENDS
  "${PROJECT_SOURCE_DIR}/modules/*.cpp" "${PROJECT_SOURCE_DIR}/modules/*.hpp"
  "${PROJECT_SOURCE_DIR}/modules/*.h" "${PROJECT_SOURCE_DIR}/modules/*.inc"
  "${PROJECT_SOURCE_DIR}/modules/CMakeLists.txt" "${PROJECT_SOURCE_DIR}/cmake/*.cmake"
  "${HYPERDR_MODEL_ASSET_DIR}/*.ncnn.*" "${HYPERDR_MODEL_ASSET_DIR}/*.manifest.json")
list(APPEND hyperdr_identity_inputs "${PROJECT_SOURCE_DIR}/CMakeLists.txt"
  "${PROJECT_SOURCE_DIR}/vcpkg.json")
list(SORT hyperdr_identity_inputs)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${hyperdr_identity_inputs})
string(TOUPPER "${CMAKE_BUILD_TYPE}" hyperdr_identity_configuration)
set(hyperdr_identity "${PROJECT_VERSION}|${CMAKE_CXX_COMPILER_ID}|${CMAKE_CXX_COMPILER_VERSION}|${CMAKE_BUILD_TYPE}|${CMAKE_CXX_FLAGS}|${CMAKE_CXX_FLAGS_${hyperdr_identity_configuration}}|${CMAKE_OSX_SYSROOT}|${CMAKE_OSX_ARCHITECTURES}|${CMAKE_OSX_DEPLOYMENT_TARGET}|codecs=${HYPERDR_WITH_CODECS}|ncnn=${HYPERDR_WITH_NCNN}")
foreach(hyperdr_input IN LISTS hyperdr_identity_inputs)
  file(SHA256 "${hyperdr_input}" hyperdr_input_hash)
  string(APPEND hyperdr_identity "|${hyperdr_input_hash}")
endforeach()
# Record the actual installed package revisions, including port versions.
if(HYPERDR_WITH_CODECS AND EXISTS "${VCPKG_INSTALLED_DIR}/vcpkg/status")
  file(READ "${VCPKG_INSTALLED_DIR}/vcpkg/status" hyperdr_dependency_status)
  string(APPEND hyperdr_identity "|${hyperdr_dependency_status}")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${VCPKG_INSTALLED_DIR}/vcpkg/status")
endif()
string(SHA256 HYPERDR_BUILD_ID "${hyperdr_identity}")

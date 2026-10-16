set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_DEPLOYMENT_TARGET "26.0")

# Transitional desktop decoder libraries must remain replaceable (LGPLv3).
if(PORT MATCHES "^(libheif|libde265)$")
  set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()

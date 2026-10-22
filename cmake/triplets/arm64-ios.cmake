# iOS device slice of the engine xcframework.
#
# The port files build with the deployment target vcpkg forwards to CMake, so the
# static libraries match HyperDR's own minimum (docs: gpu-pipeline.md §2).
# Static only: the app bundle links one archive and embeds no dylib.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_DEPLOYMENT_TARGET "27.0")

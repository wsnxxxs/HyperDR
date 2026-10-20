# iOS simulator slice of the engine xcframework.
#
# Same settings as arm64-ios with the simulator SDK; keeping it a separate
# triplet is what lets vcpkg cache the two slices independently.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphonesimulator)
set(VCPKG_OSX_DEPLOYMENT_TARGET "26.0")

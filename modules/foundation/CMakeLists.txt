# Numeric helpers, JSON, file IO, hashing, and the row-parallel thread pool.
# Depends on nothing but the standard library and threads.
hyperdr_add_module(foundation
  SOURCES
    src/file_io.cpp
    src/hash.cpp
    src/json.cpp
    src/json_writer.cpp
  DEPENDS Threads::Threads)

if(WIN32)
  target_sources(hyperdr_foundation PRIVATE src/file_io_windows.cpp)
else()
  target_sources(hyperdr_foundation PRIVATE src/file_io_posix.cpp)
  if(APPLE)
    target_link_libraries(hyperdr_foundation PRIVATE "-framework CoreFoundation")
  endif()
endif()

add_subdirectory(tests)

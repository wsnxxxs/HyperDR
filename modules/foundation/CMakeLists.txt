# Numeric helpers, JSON, file IO, hashing, and the row-parallel thread pool.
# Depends on nothing but the standard library and threads.
hyperdr_add_module(foundation
  SOURCES
    src/file_io.cpp
    src/hash.cpp
    src/json.cpp
    src/json_writer.cpp
  DEPENDS Threads::Threads)

add_subdirectory(tests)

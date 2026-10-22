# Generate one externally linked, aligned byte array and its length.
file(READ "${INPUT}" bytes HEX)
file(SIZE "${INPUT}" size)
# Short rows also stay below MSVC's source-line length limit.
string(REPEAT "[0-9a-f][0-9a-f]" 16 row)
string(REGEX REPLACE "(${row})" "\\1\n" bytes "${bytes}")
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${bytes}")
get_filename_component(directory "${OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${directory}")
file(WRITE "${OUTPUT}"
  "#include <cstddef>\nnamespace hyperdr::model_assets {\n"
  "alignas(16) extern const unsigned char ${SYMBOL}[] = {\n${bytes}\n};\n"
  "extern const std::size_t ${SYMBOL}_size = ${size};\n}\n")

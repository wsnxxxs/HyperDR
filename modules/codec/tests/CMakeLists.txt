# The codec tests encode and decode real files, so they only exist in the
# codec-enabled configuration.
hyperdr_add_test(dcp_reader_test LINK HyperDR::codec)
hyperdr_add_test(lens_profile_test LINK HyperDR::codec)
if(HYPERDR_WITH_CODECS)
  hyperdr_add_test(icc_color_test LINK HyperDR::image lcms2::lcms2)
  hyperdr_add_test(png_decode_test LINK HyperDR::codec PNG::PNG lcms2::lcms2)
  if(TARGET png_decode_test)
    hyperdr_copy_libultrahdr(png_decode_test)
  endif()
  # `heif` as well as the module: the test builds its own HEIF fixtures, so it
  # includes <libheif/heif.h> directly, and the module deliberately keeps that
  # dependency private. Without this the only test that exercises the real
  # codec paths fails to compile, which is how it came to be skipped silently.
  hyperdr_add_test(codec_test LINK HyperDR::codec heif avif PNG::PNG lcms2::lcms2)
  hyperdr_add_test(heif_parallel_test LINK HyperDR::codec heif)
  hyperdr_add_test(alpha_decode_test LINK HyperDR::codec heif avif)
  if(TARGET heif_parallel_test)
    hyperdr_restore_x265_multibit(heif_parallel_test)
    hyperdr_copy_libultrahdr(heif_parallel_test)
  endif()
  if(TARGET alpha_decode_test)
    hyperdr_restore_x265_multibit(alpha_decode_test)
    hyperdr_copy_libultrahdr(alpha_decode_test)
  endif()
  if(TARGET codec_test)
    hyperdr_restore_x265_multibit(codec_test)
    hyperdr_copy_libultrahdr(codec_test)
  endif()

  # Writes its own DNG fixture and decodes it through LibRaw, so it needs the
  # module but none of the container libraries.
  hyperdr_add_test(raw_highlight_test LINK HyperDR::codec)
  hyperdr_add_test(raw_geometry_test LINK HyperDR::image)
  hyperdr_add_test(raw_sensor_geometry_test)

  # Pure boundary tests: no giant fixture or allocation is needed to pin the
  # maximum RAW dimensions and the overflow-safe arithmetic.
  hyperdr_add_test(budget_test)

  # The DNG opcode lists the RAW decoder applies, as bytes and arithmetic.
  hyperdr_add_test(dng_opcode_test)
endif()

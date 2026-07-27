# The codec tests encode and decode real files, so they only exist in the
# codec-enabled configuration.
if(HYPERDR_WITH_CODECS)
  # `heif` as well as the module: the test builds its own HEIF fixtures, so it
  # includes <libheif/heif.h> directly, and the module deliberately keeps that
  # dependency private. Without this the only test that exercises the real
  # codec paths fails to compile, which is how it came to be skipped silently.
  hyperdr_add_test(codec_test LINK HyperDR::codec heif)
  if(TARGET codec_test)
    hyperdr_restore_x265_multibit(codec_test)
    hyperdr_copy_libultrahdr(codec_test)
  endif()

  # Writes its own DNG fixture and decodes it through LibRaw, so it needs the
  # module but none of the container libraries.
  hyperdr_add_test(raw_highlight_test LINK HyperDR::codec)

  # Pure boundary tests: no giant fixture or allocation is needed to pin the
  # maximum RAW dimensions and the overflow-safe arithmetic.
  hyperdr_add_test(budget_test)
endif()

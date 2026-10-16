# Frozen CNN and EXIF-assisted model assets, embedded in the executable.
set(HYPERDR_MODEL_ASSET_DIR
    "${PROJECT_SOURCE_DIR}/HyperDR_Model/models"
    CACHE PATH "Directory containing frozen HyperDR model assets")
option(HYPERDR_WITH_NCNN
  "Build the native model runtime against the vcpkg ncnn package" ON)

set(HYPERDR_RESEARCH_CNN_PARAM
    "${HYPERDR_MODEL_ASSET_DIR}/research-cnn-v1.ncnn.param")
set(HYPERDR_RESEARCH_CNN_BIN
    "${HYPERDR_MODEL_ASSET_DIR}/research-cnn-v1.ncnn.bin")
set(HYPERDR_RESEARCH_CNN_METADATA
    "${HYPERDR_MODEL_ASSET_DIR}/research-cnn-v1.ncnn.json")
set(HYPERDR_RESEARCH_CNN_MANIFEST
    "${HYPERDR_MODEL_ASSET_DIR}/research-cnn-v1.manifest.json")
set(HYPERDR_RESEARCH_EXIF_PARAM
    "${HYPERDR_MODEL_ASSET_DIR}/research-exif-v1.ncnn.param")
set(HYPERDR_RESEARCH_EXIF_BIN
    "${HYPERDR_MODEL_ASSET_DIR}/research-exif-v1.ncnn.bin")
set(HYPERDR_RESEARCH_EXIF_METADATA
    "${HYPERDR_MODEL_ASSET_DIR}/research-exif-v1.ncnn.json")
set(HYPERDR_RESEARCH_EXIF_MANIFEST
    "${HYPERDR_MODEL_ASSET_DIR}/research-exif-v1.manifest.json")
set(HYPERDR_RESEARCH_ASSET_FILES
    "${HYPERDR_RESEARCH_CNN_PARAM}" "${HYPERDR_RESEARCH_CNN_BIN}"
    "${HYPERDR_RESEARCH_CNN_METADATA}" "${HYPERDR_RESEARCH_CNN_MANIFEST}"
    "${HYPERDR_RESEARCH_EXIF_PARAM}" "${HYPERDR_RESEARCH_EXIF_BIN}"
    "${HYPERDR_RESEARCH_EXIF_METADATA}" "${HYPERDR_RESEARCH_EXIF_MANIFEST}")
# The estimator's numbers are compiled in, not loaded, so a mismatch between the
# generated header and its manifest would be a silent behavioural difference.
# Both are listed as build inputs and the header is checked to exist.
set(HYPERDR_RESEARCH_EXIF_LEVEL_DATA
    "${PROJECT_SOURCE_DIR}/modules/gainmap/src/research_exif_level_data.inc")

function(hyperdr_configure_model)
  if(NOT EXISTS "${HYPERDR_RESEARCH_EXIF_LEVEL_DATA}")
    message(FATAL_ERROR
      "Missing ${HYPERDR_RESEARCH_EXIF_LEVEL_DATA}; regenerate the research "
      "assets with HyperDR_Model/scripts/export_research_assets.py")
  endif()

  # This target is useful to package/test jobs even when ncnn itself is not
  # enabled.  It depends on real files and therefore cannot pass by creating
  # an empty placeholder.
  add_custom_target(HyperDRModelNcnnAssets
    DEPENDS ${HYPERDR_RESEARCH_ASSET_FILES}
            "${HYPERDR_RESEARCH_EXIF_LEVEL_DATA}")
  set(HYPERDR_MODEL_ASSET_TARGET HyperDRModelNcnnAssets)

  if(HYPERDR_WITH_NCNN)
    find_package(ncnn CONFIG REQUIRED)
    if(TARGET ncnn)
      set(HYPERDR_NCNN_TARGET ncnn)
    elseif(TARGET ncnn::ncnn)
      set(HYPERDR_NCNN_TARGET ncnn::ncnn)
    else()
      message(FATAL_ERROR
        "ncnn was found, but its package exports neither ncnn nor ncnn::ncnn")
    endif()
    set(HYPERDR_NCNN_TARGET "${HYPERDR_NCNN_TARGET}" CACHE INTERNAL
        "Resolved ncnn target for native model runtime")
    # Every selectable model must have its bytes. A build that shipped the
    # dropdown without one of the assets would offer an option that fails only
    # when a user picks it.
    foreach(asset IN LISTS HYPERDR_RESEARCH_ASSET_FILES)
      if(NOT EXISTS "${asset}")
        message(FATAL_ERROR
          "Missing research model asset ${asset}; regenerate it with "
          "HyperDR_Model/scripts/export_research_assets.py")
      endif()
    endforeach()
    # Native C++ model code can link this interface target and depend on the
    # model asset target without duplicating package/runtime policy here.
    add_library(HyperDR::model_assets INTERFACE IMPORTED GLOBAL)
    add_dependencies(HyperDR::model_assets ${HYPERDR_MODEL_ASSET_TARGET})
    set_property(TARGET HyperDR::model_assets PROPERTY
      INTERFACE_LINK_LIBRARIES "${HYPERDR_NCNN_TARGET}")

    set(model_sources)
    foreach(model research-cnn-v1 research-exif-v1)
      foreach(kind param bin)
        string(REPLACE "-" "_" symbol "${model}_${kind}")
        set(output "${CMAKE_BINARY_DIR}/generated/${symbol}.cpp")
        add_custom_command(OUTPUT "${output}"
          COMMAND ${CMAKE_COMMAND}
            "-DINPUT=${HYPERDR_MODEL_ASSET_DIR}/${model}.ncnn.${kind}"
            "-DOUTPUT=${output}" "-DSYMBOL=${symbol}"
            -P "${PROJECT_SOURCE_DIR}/cmake/embed_binary.cmake"
          DEPENDS "${HYPERDR_MODEL_ASSET_DIR}/${model}.ncnn.${kind}"
                  "${PROJECT_SOURCE_DIR}/cmake/embed_binary.cmake"
          VERBATIM)
        list(APPEND model_sources "${output}")
      endforeach()
    endforeach()
    add_custom_target(HyperDRModelEmbedded DEPENDS ${model_sources})
    set(HYPERDR_MODEL_SOURCES "${model_sources}" CACHE INTERNAL
        "Generated aligned ncnn model arrays")
  endif()
endfunction()

function(hyperdr_install_model_assets)
  # The native library owns the model bytes as aligned arrays.  Keep
  # ONNX and ncnn files in the source tree for offline conversion/auditing,
  # but do not install an external model path that could drift from the
  # embedded arrays (and do not install a PyTorch runtime).
endfunction()

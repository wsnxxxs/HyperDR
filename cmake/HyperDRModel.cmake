# Frozen model assets and optional ncnn dependency.
#
# The application may use ncnn without carrying PyTorch in a release image.
# The checked-in feature ONNX is exported from the frozen checkpoint by
# HyperDR_Model/export_onnx.py; the checked-in param/bin pair is then generated
# from that ONNX by HyperDR_Model/scripts/convert_ncnn.py.  The
# HYPERDR_REGENERATE_NCNN_MODEL option keeps the ONNX->ncnn conversion
# reproducible for a deliberate model refresh, but never invents a fallback
# asset when pnnx is unavailable.

set(HYPERDR_MODEL_ASSET_DIR
    "${PROJECT_SOURCE_DIR}/HyperDR_Model/models"
    CACHE PATH "Directory containing frozen HyperDR model assets")
set(HYPERDR_MODEL_NCNN_HEIGHT 192 CACHE STRING "Fixed ncnn model input height")
set(HYPERDR_MODEL_NCNN_WIDTH 256 CACHE STRING "Fixed ncnn model input width")
option(HYPERDR_WITH_NCNN
  "Build the native model runtime against the vcpkg ncnn package" ON)
option(HYPERDR_REGENERATE_NCNN_MODEL
  "Regenerate ncnn param/bin from the frozen ONNX asset at build time" OFF)
set(HYPERDR_MODEL_ONNX
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.onnx")
set(HYPERDR_MODEL_ONNX_METADATA
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.onnx.json")
set(HYPERDR_MODEL_FEATURE_ONNX
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.features.onnx")
set(HYPERDR_MODEL_NCNN_PARAM
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.ncnn.param")
set(HYPERDR_MODEL_NCNN_BIN
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.ncnn.bin")
set(HYPERDR_MODEL_NCNN_METADATA
    "${HYPERDR_MODEL_ASSET_DIR}/production-v3.ncnn.json")

function(hyperdr_configure_model)
  foreach(asset IN ITEMS
      HYPERDR_MODEL_ONNX
      HYPERDR_MODEL_ONNX_METADATA
      HYPERDR_MODEL_FEATURE_ONNX)
    if(NOT EXISTS "${${asset}}")
      message(FATAL_ERROR "Missing frozen model asset ${${asset}}")
    endif()
  endforeach()

  # This target is useful to package/test jobs even when ncnn itself is not
  # enabled.  It depends on real files and therefore cannot pass by creating
  # an empty placeholder.
  add_custom_target(HyperDRModelNcnnAssets
    DEPENDS "${HYPERDR_MODEL_NCNN_PARAM}"
            "${HYPERDR_MODEL_NCNN_BIN}"
            "${HYPERDR_MODEL_NCNN_METADATA}")
  set(HYPERDR_MODEL_ASSET_TARGET HyperDRModelNcnnAssets)

  if(HYPERDR_REGENERATE_NCNN_MODEL)
    if(NOT HYPERDR_WITH_NCNN)
      message(FATAL_ERROR
        "HYPERDR_REGENERATE_NCNN_MODEL requires HYPERDR_WITH_NCNN=ON")
    endif()
    if(NOT HYPERDR_MODEL_PYTHON)
      find_package(Python3 COMPONENTS Interpreter QUIET)
      if(Python3_Interpreter_FOUND)
        set(HYPERDR_MODEL_PYTHON "${Python3_EXECUTABLE}"
            CACHE FILEPATH "Python used only for build-time model conversion")
      endif()
    endif()
    if(NOT HYPERDR_MODEL_PYTHON)
      message(FATAL_ERROR
        "Set HYPERDR_MODEL_PYTHON to a Python with torch/onnx/onnxscript "
        "when HYPERDR_REGENERATE_NCNN_MODEL is enabled")
    endif()
    if(NOT HYPERDR_PNNX_EXECUTABLE)
      find_program(HYPERDR_PNNX_EXECUTABLE NAMES pnnx)
    endif()
    if(NOT HYPERDR_PNNX_EXECUTABLE)
      message(FATAL_ERROR
        "Set HYPERDR_PNNX_EXECUTABLE to the pinned pnnx converter; refusing "
        "to fabricate ncnn weights")
    endif()
    set(HYPERDR_GENERATED_MODEL_DIR
        "${CMAKE_BINARY_DIR}/HyperDR_Model/models")
    set(HYPERDR_GENERATED_NCNN_PARAM
        "${HYPERDR_GENERATED_MODEL_DIR}/production-v3.ncnn.param")
    set(HYPERDR_GENERATED_NCNN_BIN
        "${HYPERDR_GENERATED_MODEL_DIR}/production-v3.ncnn.bin")
    set(HYPERDR_GENERATED_NCNN_METADATA
        "${HYPERDR_GENERATED_MODEL_DIR}/production-v3.ncnn.json")
    add_custom_command(
      OUTPUT
        "${HYPERDR_GENERATED_NCNN_PARAM}"
        "${HYPERDR_GENERATED_NCNN_BIN}"
        "${HYPERDR_GENERATED_NCNN_METADATA}"
      COMMAND "${CMAKE_COMMAND}" -E make_directory
              "${HYPERDR_GENERATED_MODEL_DIR}"
      COMMAND "${HYPERDR_MODEL_PYTHON}"
              "${PROJECT_SOURCE_DIR}/HyperDR_Model/scripts/convert_ncnn.py"
              --checkpoint
              "${PROJECT_SOURCE_DIR}/HyperDR_Model/checkpoints/production-v3.pt"
              --source-onnx "${HYPERDR_MODEL_FEATURE_ONNX}"
              --output-dir "${HYPERDR_GENERATED_MODEL_DIR}"
              --pnnx "${HYPERDR_PNNX_EXECUTABLE}"
              --height "${HYPERDR_MODEL_NCNN_HEIGHT}"
              --width "${HYPERDR_MODEL_NCNN_WIDTH}"
      DEPENDS
        "${HYPERDR_MODEL_FEATURE_ONNX}"
        "${PROJECT_SOURCE_DIR}/HyperDR_Model/scripts/convert_ncnn.py"
        "${PROJECT_SOURCE_DIR}/HyperDR_Model/export_onnx.py"
        "${PROJECT_SOURCE_DIR}/HyperDR_Model/hyperdr_ml/model.py"
        "${PROJECT_SOURCE_DIR}/HyperDR_Model/checkpoints/production-v3.pt"
      VERBATIM)
    add_custom_target(HyperDRModelNcnnGenerated ALL
      DEPENDS "${HYPERDR_GENERATED_NCNN_PARAM}"
              "${HYPERDR_GENERATED_NCNN_BIN}"
              "${HYPERDR_GENERATED_NCNN_METADATA}")
    set(HYPERDR_MODEL_ASSET_TARGET HyperDRModelNcnnGenerated)
    # Native model targets can depend on this target when a deliberate model
    # refresh is requested.  Keep the checked-in paths as the default API.
    set(HYPERDR_MODEL_NCNN_PARAM "${HYPERDR_GENERATED_NCNN_PARAM}")
    set(HYPERDR_MODEL_NCNN_BIN "${HYPERDR_GENERATED_NCNN_BIN}")
    set(HYPERDR_MODEL_NCNN_METADATA "${HYPERDR_GENERATED_NCNN_METADATA}")
    set(HYPERDR_MODEL_NCNN_PARAM "${HYPERDR_GENERATED_NCNN_PARAM}" PARENT_SCOPE)
    set(HYPERDR_MODEL_NCNN_BIN "${HYPERDR_GENERATED_NCNN_BIN}" PARENT_SCOPE)
    set(HYPERDR_MODEL_NCNN_METADATA "${HYPERDR_GENERATED_NCNN_METADATA}" PARENT_SCOPE)
  endif()

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
    set(HYPERDR_MODEL_NCNN_PARAM "${HYPERDR_MODEL_NCNN_PARAM}" CACHE FILEPATH
        "Resolved ncnn param asset for the native model runtime")
    set(HYPERDR_MODEL_NCNN_BIN "${HYPERDR_MODEL_NCNN_BIN}" CACHE FILEPATH
        "Resolved ncnn weights asset for the native model runtime")
    set(HYPERDR_MODEL_NCNN_METADATA "${HYPERDR_MODEL_NCNN_METADATA}" CACHE FILEPATH
        "Resolved ncnn manifest for the native model runtime")
    foreach(asset IN ITEMS HYPERDR_MODEL_NCNN_PARAM HYPERDR_MODEL_NCNN_BIN HYPERDR_MODEL_NCNN_METADATA)
      if(NOT EXISTS "${${asset}}" AND NOT HYPERDR_REGENERATE_NCNN_MODEL)
        message(FATAL_ERROR "Missing ncnn model asset ${${asset}}")
      endif()
    endforeach()
    # Native C++ model code can link this interface target and depend on the
    # model asset target without duplicating package/runtime policy here.
    add_library(HyperDR::model_assets INTERFACE IMPORTED GLOBAL)
    add_dependencies(HyperDR::model_assets ${HYPERDR_MODEL_ASSET_TARGET})
    set_property(TARGET HyperDR::model_assets PROPERTY
      INTERFACE_LINK_LIBRARIES "${HYPERDR_NCNN_TARGET}")

    # The resource compiler embeds the exact checked-in (or deliberately
    # regenerated) bytes in HyperDR.exe.  Runtime inference never opens a
    # user-controlled .param/.bin path.
    set(HYPERDR_MODEL_RESOURCE_FILE
        "${CMAKE_BINARY_DIR}/hyperdr_ncnn_model.rc")
    configure_file(
      "${PROJECT_SOURCE_DIR}/cmake/HyperDRModel.rc.in"
      "${HYPERDR_MODEL_RESOURCE_FILE}" @ONLY)
    set(HYPERDR_MODEL_RESOURCE_FILE "${HYPERDR_MODEL_RESOURCE_FILE}"
        CACHE INTERNAL "Generated ncnn RCDATA resource file")
    if(HYPERDR_REGENERATE_NCNN_MODEL)
      add_dependencies(HyperDRModelNcnnGenerated HyperDRModelNcnnAssets)
    endif()
  endif()
endfunction()

function(hyperdr_install_model_assets)
  # The release executable owns the model bytes as RCDATA resources.  Keep
  # ONNX and ncnn files in the source tree for offline conversion/auditing,
  # but do not install an external model path that could drift from the
  # embedded resources (and do not install a PyTorch runtime).
endfunction()

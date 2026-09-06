#pragma once

namespace hyperdr {

// Installs the embedded ncnn runtime callback used by --ai-model.  The model
// param/bin bytes are linked into HyperDR.exe as RCDATA resources; no external
// model file is opened.  Returns false only when this build was made without
// HYPERDR_WITH_NCNN.
[[nodiscard]] bool install_embedded_ncnn_runtime();

}  // namespace hyperdr

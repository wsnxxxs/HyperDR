# Private AI models

The weights and fitted EXIF trees are private and excluded from Git. Published
releases omit them; builds without `research-cnn-v1` offer Captured and Expand.

For a private build, place `research-cnn-v1.mlpackage` here. Optionally add both
`research-exif-v1.mlpackage` and `research-exif-v1.exif-level.json`. The provider
uses model 2 when all six ordinary capture fields are usable, otherwise model 1.
A missing EXIF tree or spatial package also falls back to model 1. Compiled
`.mlmodelc` directories are accepted in place of `.mlpackage`.

Both models use five linear Display-P3 feature planes and a stride-16 output.
Both reconstruct with `HDR = (base + 1e-5) * 2^stops - 1e-5`. Predictions carry
this offset; the graph converts the reconstructed HDR into its destination
pair before combining AI and captured gain, including black channels.
Model 2 removes the spatial grid's mean in double precision and restores the
EXIF estimator's predicted level. Preview, detail and export share this provider.
The private JSON is the original `export_research_assets.py` tree export; it is
loaded as data, never embedded in Swift or test fixtures.

Convert the private ONNX graph with `HyperDR_Model/scripts/convert_coreml.py`,
passing `--model-id research-exif-v1 --precision float32`, the matching `--onnx`
and `--output`, and
`--install` pointing at this directory. The converter targets macOS 15 / iOS 18
(the app itself requires iOS 27). Spatial dimensions remain flexible. Model 2 uses float32 to keep its
mean-removed grid close to the ONNX reference; the package is about 2.6 MB.

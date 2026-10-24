# AI model

The AI gain model (`research-cnn-v1.mlpackage`) is not part of the open-source
repository. Builds made from a plain checkout have no model: the HDR source
offers the analytic expansion (and, for RAW, the captured highlights), and the
AI sources are shown as unavailable.

Official builds put a private copy of the package in this directory before
building; `.gitignore` keeps it out of Git. `ModelGain.bundledModel` looks for
`research-cnn-v1.mlmodelc` or `research-cnn-v1.mlpackage` here.

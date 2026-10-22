# Offline denoising research

Experimental NAFNet evaluation tools; these are not integrated into HyperDR or
bundled with the app. The app uses CIRAWFilter RAW development and its supported
noise-reduction controls. No model checkpoint or dataset is included.

`fetch_rawnind.py` downloads selected RawNIND pairs (CC BY-SA 4.0) to a local
folder; `develop_raw.swift` develops the RAW captures; `eval_pairs.py` compares
Apple development and NAFNet. See each script's help or header for usage.
The NAFNet implementation requires PyTorch; evaluation additionally uses NumPy,
tifffile. Keep downloaded material and outputs under `build/`.

`nafnet.py` derives from the MIT-licensed NAFNet implementation by megvii-model.
See `NAFNet-LICENSE.txt` for the upstream license text.

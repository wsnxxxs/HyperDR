# Install HyperDR on Windows

This release archive contains the application runtime only. It does not contain
the source tree or tests.

1. Extract the archive to a location where you have write access, such as
   `C:\Apps\HyperDR`. Any location works; nothing is stored next to the
   program.
2. Install Python 3.11 or newer from python.org, including `tkinter` and the
   option to add Python to `PATH`.
3. For phone HDR setup in this source-based archive, install the small certificate dependency:
   `python -m pip install -r apps/panel/requirements.txt`.
   The packaged Tauri desktop app already bundles it.
4. Double-click `Start.bat`, then open **Phone workbench → Enable HDR preview**.
   Scan the setup QR and follow the iOS or Android certificate instructions.

The editor stays local; the phone listener opens only when enabled. Keep the
terminal open while using the source-based panel.

## Native “AI 优化”

The production model and inference weights are embedded in `HyperDR.exe` and
run through the bundled native runtime. No PyTorch installation, checkpoint,
model script, or model-specific Python environment is required.

## Phone HDR and HTTPS

The workbench generates a CA unique to this installation without installing
mkcert or changing the computer trust store. iOS requires both installing the
profile and enabling full trust; Android requires installing a CA certificate.
The setup page provides these steps and the phone reports actual rendering
capabilities. Unsupported devices continue to use SDR previews.

Certificates live in `%LOCALAPPDATA%\HyperDR\tls`. Reconnecting checks address
coverage and renews the server certificate using the same root. Uploads finish
before a listener switch. The certificate-only HTTP setup listener expires after
15 minutes or closes when HTTPS verification succeeds. See `docs\iphone-lan.md`.

`Setup-HTTPS.bat` remains a command-line alternative and uses the same CA manager.
No CA or private key is included in a release archive.

For command-line use, run `bin\HyperDR.exe` from a terminal. The package
includes the required native runtime DLLs, including the dual Main10/8-bit x265
pair used by PQ, HLG, and gain-map HEIC. Every release archive is unpacked after
packaging and must convert and self-verify a generated test image in all six
output encodings before the package command succeeds. You may need the Microsoft
Visual C++ Redistributable if Windows reports a missing MSVC runtime DLL.

# HyperDR Desktop

This directory contains the Tauri 2 Windows shell. The first desktop version
keeps the existing Python panel as a sidecar:

```text
Tauri window -> WebView2 -> Python panel server -> HyperDR.exe
```

The Python server is launched with `--desktop`, binds to loopback, and prints
one machine-readable line:

```text
HYPERDR_READY http://127.0.0.1:<port>/?token=<temporary-token>
```

Tauri waits for that line, then navigates the window to the existing panel.
This keeps the `/api/*` contract and the WebGPU preview unchanged while the
desktop lifecycle becomes native.

## Development

Install Rust, Node.js, and the Python build dependency from
`apps/desktop/requirements.txt`. From this directory:

```powershell
npm install
npm run dev
```

Debug builds start `apps/panel/hyperdr_gui.py` with the active Python
interpreter. Set `HYPERDR_PANEL_PYTHON` when the panel or model uses a specific
virtual environment.

## Windows release build

`tauri build` runs `packaging/build-tauri-sidecar.ps1` first. That script uses
PyInstaller to create a one-file Python sidecar, embeds the selected native
HyperDR executable and its sibling DLLs, and places the target-triple-named
executable under `src-tauri/binaries/` for Tauri bundling. The sidecar unpacks
its private runtime into a temporary directory at startup; the user still sees
only the Tauri window because Tauri launches it without a console window.

The generated `binaries/` and sidecar build directories are intentionally
ignored by Git. They are release artifacts, not source files.

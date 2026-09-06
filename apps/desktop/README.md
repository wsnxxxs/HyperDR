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

## Application icon

`src-tauri/icons/icon.svg` is the shared brand source, using the approved moon
design from `designs/logo-moon-balanced/moon-balanced-larger-offset.svg`.
After editing the source, run `npm run icons` here to regenerate native icons
and synchronize the splash, editor, phone workbench, favicon and Apple touch icon.
Native executable and installer icons take effect in the next desktop build.

## Windows release build

`tauri build` runs `packaging/build-tauri-sidecar.ps1` first. That script uses
PyInstaller to create a one-file Python sidecar, embeds the selected native
HyperDR executable and its sibling DLLs, and places the target-triple-named
executable under `src-tauri/binaries/` for Tauri bundling. The production model
is already embedded in `HyperDR.exe`, so the sidecar carries no checkpoint,
model Python code, or PyTorch dependency. The sidecar unpacks its private
runtime into a temporary directory at startup; the user still sees only the
Tauri window because Tauri launches it without a console window.

The generated `binaries/` and sidecar build directories are intentionally
ignored by Git. They are release artifacts, not source files.

The build hook clears earlier HyperDR NSIS/MSI installers from the selected
Cargo target's bundle directory before Tauri creates the new installer. Use
`src-tauri/target/release/bundle/nsis/HyperDR_<version>_x64-setup.exe` for the
default build. Building creates this installer; it does not update the installed
application until you run it.

The installer reuses the registered installation directory (by default
`%LOCALAPPDATA%\HyperDR`). Reinstalling the same version replaces both the shell
and the bundled panel. Install and uninstall hooks also check for a leftover
panel process, using Tauri's existing close-app prompt before replacing files.
User workspaces and TLS certificates are retained. Bump the shared release
version for a new release; repeated `1.0.0` builds cannot be distinguished by
Windows' installed-app version display.

## Windows desktop integrations

The WebView2 instance is created with `WebGPU` and
`UseDisplayP3ColorSpace` enabled, so an HDR-enabled Windows display can use the
panel's Display-P3 extended-range preview path. The Tauri shell also owns the
Python sidecar with a Windows Job Object and a `taskkill /T /F` fallback; closing
the window therefore tears down the PyInstaller bootstrapper and any
`HyperDR.exe` child processes together.

Windows native file drops are forwarded as absolute paths to the desktop-only
`/api/native-input` route. The panel validates the source and keeps it as the
session input without copying the RAW into the HTTP workspace. Browser and LAN
servers keep the existing streamed-upload path.

## Phone workbench

The title-bar phone button starts a separate LAN listener on demand (8757, or
another available port). The desktop server stays on loopback and retains its
native-path input. The phone has its own UI, upload handoff, SSE subscription and
result downloads. Closing the connection stops the LAN listener; closing the
app stops both servers. Existing trusted TLS certificates are loaded from the
HyperDR user configuration directory. See [phone workbench](../../docs/iphone-lan.md).

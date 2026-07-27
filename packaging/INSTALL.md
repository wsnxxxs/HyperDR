# Install HyperDR on Windows

This release archive contains the application runtime only. It does not contain
the source tree or tests.

1. Extract the archive to a location where you have write access, such as
   `C:\Apps\HyperDR`. Any location works; nothing is stored next to the
   program.
2. Install Python 3.11 or newer from python.org, including `tkinter` and the
   option to add Python to `PATH`.
3. Double-click `Setup-HTTPS.bat` once, and follow the two iPhone steps it
   prints. Skip this only if you will never use the iPhone HDR preview.
4. Double-click `Start.bat`.

The application starts a local HyperDR panel and prints a temporary LAN URL.
Keep the terminal open while using the panel.

## Why step 3 is not optional for true HDR

Safari renders the real HDR preview through WebGPU, which browsers expose only
in a secure context. Over plain HTTP the panel still uploads, converts and
downloads correctly, and the final HEIC is still HDR in Photos, but the live
preview falls back to an SDR approximation. Dismissing a certificate warning is
not a substitute: an exception does not create a secure context.

`Setup-HTTPS.bat` installs `mkcert` through winget if needed, generates a
certificate authority **unique to this computer**, issues a server certificate
for your current LAN address, and exports the public root certificate to your
desktop so you can send it to the phone. No certificate authority and no
private key is ever shipped inside this archive: a shared one would let anyone
holding it impersonate any site your phone trusts.

Certificates are written to `%LOCALAPPDATA%\HyperDR\tls`, so moving or
re-extracting the program never breaks HTTPS. If your router later hands the
computer a different IP address, `Start.bat` re-issues the server certificate
from the same authority automatically; the phone needs no changes. See
`docs\iphone-lan.md` for the details.

For command-line use, run `bin\HyperDR.exe` from a terminal. The package
includes the required native runtime DLLs, including the dual Main10/8-bit x265
pair used by PQ, HLG, and gain-map HEIC. Every release archive is unpacked after
packaging and must convert and self-verify a generated test image in all six
output encodings before the package command succeeds. You may need the Microsoft
Visual C++ Redistributable if Windows reports a missing MSVC runtime DLL.

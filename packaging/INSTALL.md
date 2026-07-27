# Install HyperDR on Windows

This release archive contains the application runtime only. It does not contain
the source tree or tests.

1. Extract the archive to a location where you have write access, such as
   `C:\Apps\HyperDR`.
2. Install Python 3.11 or newer from python.org, including `tkinter` and the
   option to add Python to `PATH`.
3. Double-click `启动界面.bat`.

The application starts a local HyperDR panel and prints a temporary LAN URL.
Keep the terminal open while using the panel. See `docs\iphone-lan.md` for
optional HTTPS setup.

For command-line use, run `bin\HyperDR.exe` from a terminal. The package
includes the required native runtime DLLs, including the dual Main10/8-bit x265
pair used by PQ, HLG, and gain-map HEIC. Every release archive is unpacked after
packaging and must convert and self-verify a generated test image in all six
output encodings before the package command succeeds. You may need the Microsoft
Visual C++ Redistributable if Windows reports a missing MSVC runtime DLL.

# Building a Windows release

Release archives must be produced with the repository script, not by collecting
the build directory manually. The script prepares the dual Main10/8-bit x265
runtime, runs CPack, extracts the resulting ZIP into a clean temporary directory,
and converts and self-verifies a generated image in all six encodings.

From Developer PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File packaging\package-release.ps1 `
  -VcpkgRoot C:\tools\vcpkg
```

The default archive is written under `dist\`. The command fails without
producing a successful handoff if:

- the vcpkg manifest dependencies or Main10 x265 source tree are unavailable;
- either `libx265.dll` or `libx265_main.dll` is missing from the unpacked ZIP;
- Adaptive HDR, Ultra HDR, PQ, HLG, AVIF PQ, or AVIF HLG conversion fails; or
- any conversion report does not record both `success` and `self_verified`.

`packaging\test-release.ps1 -Archive <zip>` can repeat only the unpacked-package
test for an existing archive. It uses generated test data and does not require a
private photograph.

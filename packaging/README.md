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
- the unpacked ZIP contains any `.pem`, `.key`, `.pfx`, `.p12`, `.crt`, or
  `.cer` file;
- `Start.bat`, `Setup-HTTPS.bat`, or any of the three PowerShell scripts they
  depend on is missing from the unpacked ZIP;
- Adaptive HDR, Ultra HDR, PQ, HLG, AVIF PQ, or AVIF HLG conversion fails; or
- any conversion report does not record both `success` and `self_verified`.

Key material is a release blocker rather than a warning. Every computer must
generate its own certificate authority through `Setup-HTTPS.bat`; a shared
authority in a published archive would let anyone holding it issue a trusted
certificate for any site, on every phone that installed it.

## Manual acceptance before publishing

The automated test cannot cover first-run experience. Before publishing, on a
Windows computer that has never run HyperDR and an iPhone that has never
installed the root certificate:

1. Extract the archive to a path containing a space and a non-ASCII character.
2. Run `Setup-HTTPS.bat`, install and fully trust the exported root certificate
   on the phone.
3. Run `Start.bat` and confirm the printed address is `https://` and that the
   phone reaches the panel with no certificate warning.
4. Confirm the status bar reports true HDR rather than an SDR approximation.
5. Move the extracted folder elsewhere and confirm `Start.bat` still serves
   HTTPS.

`packaging\test-release.ps1 -Archive <zip>` can repeat only the unpacked-package
test for an existing archive. It uses generated test data and does not require a
private photograph.

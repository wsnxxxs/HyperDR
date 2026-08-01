# Security notes

## Supported versions

Security fixes are applied to the latest version on the default branch.

## Threat model

HyperDR converts local files. The one component with an attack surface is the
browser panel, which accepts uploads over the LAN and can optionally serve them
over TLS. Treat it as a local, trusted-network tool: do not expose it directly
to the public internet, and do not port-forward its port on a router.

The panel refuses client-supplied Windows paths, output directories, and
executable paths; uploads and outputs are confined to a randomly named job
directory. See `docs/iphone-lan.md` for the full boundary.

## Certificates

`Setup-HTTPS.bat` generates a certificate authority that belongs to a single
computer. No certificate authority, and no private key of any kind, is included
in this repository or in any release archive. A shared authority would be a
serious vulnerability rather than a convenience: anyone holding its private key
could issue a trusted certificate for any site, for every phone that installed
it.

Certificates live in `%LOCALAPPDATA%\HyperDR\tls`, deliberately not in
Documents, which may be redirected into a cloud-synced folder. The server
private key is restricted to the current Windows user. The authority's own key
stays where `mkcert` puts it and is never read or copied by HyperDR.

A release archive containing a `.pem`, `.key`, `.pfx`, `.p12`, `.crt`, or `.cer`
file is a defect, not a convenience. `packaging/package-release.ps1` unpacks
every archive it builds and fails the run if it finds one, so key material
cannot reach a published package by accident.

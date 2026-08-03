# Security notes

## Supported versions

Security fixes are applied to the latest version on the default branch.

## Reporting

Report vulnerabilities by email to w1135766898@gmail.com. Reports are
acknowledged within three business days and kept confidential until a fix for
the latest version is released. Please include the version or commit you
tested, the input that triggered the issue, and what you observed.

That address is for vulnerabilities only; use the issue tracker for questions.

## Threat model

HyperDR converts local files. The one component with an attack surface is the
browser panel, which accepts uploads over the LAN and can optionally serve them
over TLS. Treat it as a local, trusted-network tool: do not expose it directly
to the public internet, and do not port-forward its port on a router.

The panel refuses client-supplied Windows paths, output directories, and
executable paths; uploads and outputs are confined to a randomly named session
directory under `hdr-workspace/`. See "安全边界" in `docs/iphone-lan.md` for the
full boundary.

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
file is a defect, not a convenience. `packaging/test-release.ps1` unpacks an
archive and fails if it finds one. It runs on every CI build and again from
`packaging/package-release.ps1`, so key material cannot reach a published
package by accident.

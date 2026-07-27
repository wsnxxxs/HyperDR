# Security policy

## Supported versions

Security fixes are applied to the latest version on the default branch.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. This source
snapshot does not yet publish a private reporting address, so it must not be
presented as having an active security intake channel. Before making the
repository public, the owner must enable GitHub private vulnerability reporting
and replace this paragraph with the repository's exact private-reporting link.

Include the affected version, platform, reproduction steps, and potential impact
in a private report. The project targets an acknowledgement within seven days
once that channel is active.

The LAN panel accepts files and can optionally use TLS. Treat it as a local,
trusted-network tool: do not expose it directly to the public internet.

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

Report any release archive found to contain a `.pem`, `.key`, `.pfx`, `.crt`, or
`.cer` file through the private channel above; the packaging test treats that as
a release blocker.

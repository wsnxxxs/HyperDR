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

HyperDR converts local files. The application and the CLI open no network
listener and make no network requests; their attack surface is the image,
container and metadata parsers that read files you choose to open. The HEIF
reader and the other parsers are fuzzed (`tests/fuzz`). Treat photographs from
untrusted sources as untrusted input.

The macOS application runs in the App Sandbox: it reads only files you open or
drop, and writes only to locations you choose or the folder you keep for
exports.

The earlier browser panel, which accepted uploads over the LAN and could serve
them over TLS, was deleted on 2026-10-20 (last visible at `722f62ce`). The
Windows version is frozen at [`6949167`](https://github.com/wsnxxxs/HyperDR/tree/6949167);
see that revision for its release, packaging and certificate handling.

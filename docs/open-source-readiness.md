# Open-source release checklist

This repository is prepared for a source release, subject to the owner actions below.

## Completed checks

- Build products, conversion outputs, RAW images, local workspaces, IDE files,
  local environment files, and common certificate formats are ignored.
- No API keys, private keys, or fixed access tokens were found in the supplied
  source-tree scan. This directory did not contain `.git`, so that result says
  nothing about commit history; record the scanned commit and repeat a history
  scan in the real Git working tree before publication.
- Launch and firewall scripts no longer contain a user-specific Python or
  certificate path.
- The project has build, usage, LAN-safety, third-party-notice, contribution,
  and security-reporting documentation.
- The source is released under the MIT License.

## Owner actions before publishing

1. Review `THIRD_PARTY_NOTICES.md`, especially the libheif/x265 GPL terms,
   HEVC patent considerations, and the licenses shipped by fetched dependencies.
   Obtain legal advice before distributing binaries or offering a hosted service.
2. Enable GitHub private vulnerability reporting, replace the placeholder
   language in `SECURITY.md` with the exact reporting link, and fill in the
   repository's About description, topics, and support contact.
3. Before the first commit, run `git status --ignored --short` and confirm that
   no personal photos, certificates, build outputs, or local caches appear as
   unignored files.

## Suggested repository metadata

- Description: `Convert ARW, DNG, and common images to Adaptive HDR HEIC, Ultra HDR JPEG, PQ HEIC, and HLG HEIC.`
- Topics: `hdr`, `ultra-hdr`, `adaptive-hdr`, `heic`, `heif`, `raw`, `arw`, `photography`, `cpp`, `windows`

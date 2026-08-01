# Open-source release checklist

An internal checklist, not user documentation. It is addressed to the owner and
should not ship with a public source release; see the last owner action below.

## Completed checks

- Build products, conversion outputs, RAW images, local workspaces, IDE files,
  local environment files, and common certificate formats are ignored.
- No API keys, private keys, or fixed access tokens were found in the working
  tree at `v0.3.2`. That scan covered tracked files only: it says nothing about
  commit history, Actions logs, release assets, or forks. Record the scanned
  commit and the patterns used, and repeat the scan across the full history and
  all tags before publication.
- Launch and firewall scripts no longer contain a user-specific Python or
  certificate path, and `docs/iphone-lan.md` uses a `<LAN_IP>` placeholder
  rather than a real address.
- The project has build, usage, LAN-safety, third-party-notice, and
  contribution documentation. `SECURITY.md` carries the threat model and
  certificate handling; it deliberately does not yet name a reporting channel.
- The source is released under the MIT License.

## Owner actions before publishing

1. Review `THIRD_PARTY_NOTICES.md`, especially the libheif/x265 GPL terms,
   HEVC patent considerations, and the licenses shipped by fetched dependencies.
   Obtain legal advice before distributing binaries or offering a hosted service.
2. Decide how vulnerabilities should be reported, then add that section to
   `SECURITY.md`. The decision is deliberately deferred: while the repository is
   private there are no outside reporters, and a policy that names a channel
   nobody monitors is worse than one that names none. Also fill in the
   repository's About description and topics.
3. Before publishing, run `git status --ignored --short` and confirm that no
   personal photos, certificates, build outputs, or local caches appear as
   unignored files.
4. Delete this file, or move it out of the repository. It is an owner's
   worksheet: it records what has *not* been verified, which is useful in
   private and misleading in public.

## Suggested repository metadata

- Description: `Convert ARW, DNG, and common images to Adaptive HDR HEIC, Ultra HDR JPEG, PQ HEIC, and HLG HEIC.`
- Topics: `hdr`, `ultra-hdr`, `adaptive-hdr`, `heic`, `heif`, `raw`, `arw`, `photography`, `cpp`, `windows`

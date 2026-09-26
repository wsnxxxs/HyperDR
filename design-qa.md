# Phone connection wizard design QA

## Follow-up: match settings dimensions

The user requested the phone window match Settings. The current target therefore supersedes the original concept's larger dimensions: 960 × 680, 200px rail, Settings header/footer spacing and close-button size; full-screen at widths up to 720px. QR reduced to 200px and content spacing tightened to fit.

Browser verification at 1280 × 800 measured both Settings and the phone dialog at x=160, y=60, width=960, height=680. The phone content area measured clientHeight=scrollHeight=536 (no initial vertical overflow). Additional narrow verification used a 390 × 844 CSS viewport. Latest evidence: `designs/phone-connection-wizard/settings-size-desktop.png` and `settings-size-narrow.png`. This change is CSS-only; connection logic is unchanged. The original comparison below is retained as historical evidence.

Date: 2026-09-26

Source visual truth: `designs/phone-connection-wizard/reference.png` (the user's selected second concept).
Implementation: `apps/panel/web`, served locally on port 8766.
Screenshot: `designs/phone-connection-wizard/desktop.png`.

## Evidence

- Source and final desktop capture: 1484 × 1060 pixels; CSS viewport 1484 × 1060, screenshot density 1. No density normalization required.
- State: dark theme, landscape photograph loaded, phone service enabled, waiting for a phone.
- Full comparison: `designs/phone-connection-wizard/comparison.png`.
- Focused comparison: `designs/phone-connection-wizard/comparison-dialog.png`; both dialogs cropped to 992 × 756 for readable typography and spacing review.
- Additional captures: `light.png` (1484 × 1060); narrow CSS viewport 390 × 844, with `narrow.png` saved by the browser at 375 × 812. The narrow capture is only used for responsive layout inspection, not pixel-level comparison to the desktop source.

## Findings and comparison history

The first desktop inspection found undersized headings and a narrower dialog than the concept (P2). Increased the dialog to 992 pixels, rail to 194 pixels, title to 30 pixels, and increased step/utility text and QR-to-status spacing. The final full and focused comparisons show the intended rail, centered QR, title, status, utilities and persistent footer hierarchy. No actionable P0/P1/P2 visual findings remain.

- Typography: existing system font stack retained. Readable headings and secondary text; the concept's generated font rendering differs slightly (P3).
- Spacing/layout: reference dialog proportions retained; narrow mode places steps above the content and keeps the footer accessible. Content scrolls inside the dialog when necessary.
- Colors: existing neutral dark surfaces and blue interaction tokens retained, including light-theme equivalents. Flat production surfaces intentionally replace the concept's decorative texture.
- Images: existing landscape and brand assets retained. QR is generated from the actual connection URL with the existing QR library, replacing the nonfunctional concept QR and its disclaimer. Existing editor content outside the dialog reflects the current app rather than the older source screenshot.
- Copy: connection, automatic progression and close-without-disconnecting messages match the chosen flow. Troubleshooting and optional HDR retain the real app's capabilities.

## Verification

- Browser: opened the real connection dialog, expanded troubleshooting, inspected the HDR entry and returned to the guide; closed with the close button and Escape; checked dark/light themes and 390-pixel layout. No browser console errors observed.
- Existing recovery tests pass, with focused regression coverage for waiting, connected without photo, preview, upload, reconnect and close-without-disconnecting states.
- JavaScript syntax, locale-key parity/usage and DOM-role checks pass.
- Physical-phone upload, certificate trust, actual HDR rendering and OS clipboard delivery were not end-to-end verified in this run. Existing backend behavior is unchanged.

## Implementation checklist

- [x] Dedicated native dialog and state-driven progress rail.
- [x] Preserve connection/TLS actions and preference entry point.
- [x] Theme, narrow layout, keyboard dismissal and reduced-motion support.
- [x] Compare final rendered desktop against selected visual.

final result: passed

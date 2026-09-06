# Design QA

final result: passed

## Latest revision: landscape export dialog

- Current gamut is now the first/left option, followed by limit to sRGB. Current gamut remains the default.
- Reorganized the dialog into a left photo/context column and a right settings column; retained the 3-column, 2-row format grid.
- Measured desktop dialog at 760×526 in the current 1190×985 viewport, centered with no horizontal overflow. Narrow screens stack the columns.
- Updated preview-export.png visually checked: balanced landscape proportions, consistent alignment and visible footer actions. Both gamut choices exercised; console has no errors.
- Revision result: passed.

## Previous revision: direct format and gamut selection

- Replaced the format dropdown with six radio tiles arranged in exactly three columns and two rows.
- Gamut now offers only two mutually exclusive options: limit to sRGB and current gamut. The demo records these as srgb/current rather than claiming a detected source color space.
- Browser verified three equal-position columns and two rows; selecting HLG updated headroom ceiling to 2.3. Both gamut selections and switching back to Adaptive HDR worked.
- Updated preview-export.png captures the current dialog at 1190×985. No console errors; JavaScript syntax check and diff whitespace check passed.
- Revision result: passed.

## Previous revision: remove persistent tool rail and output summary

- User requested removing all left vertical toolbar buttons and showing output settings only while exporting.
- Removed the toolbar and its reserved gutter; removed the inspector output summary and expanded the parameter scroll area. Histogram remains upper right.
- Removed obsolete button bindings and kept comparison, fit and clipping shortcuts connected directly to their actions.
- Latest evidence: preview-desktop.png, 1190×985 current browser viewport. Older large/narrow/export captures below document the earlier revision.
- Browser checks: original/comparison modes, zoom/fit, export open, HLG format change, export close. Format selector is visible only while the export dialog is open. No console errors; node syntax check passed.
- Visual check: no leftover toolbar strip or output footer; consistent left alignment of canvas, lower toolbar and metadata. No additional layout issues found.
- Revision result: passed.

## Target and evidence

- Source visual: ../desktop-darkroom-proposal/03-darkroom-concept.png, 1488×1058 raster concept, intended 1440×1024 desktop composition.
- User override: retain histogram at upper right; original concept too simple; implement an HTML demo with richer visible controls.
- Implementation: preview-desktop.png at 1280×720, preview-large.png at 1440×1024, preview-narrow.png at 390×844, preview-export.png at 1280×720.
- Density: screenshot CSS viewport corresponds to screenshot pixels (1×). Source is a generated raster, with no meaningful CSS/DPR mapping. Full-view comparison used both source and implementation in the same image-review input. Aspect ratio and responsive differences were explicitly accounted for rather than treated as pixel errors.
- State: landscape loaded, split comparison, manual settings, RGB histogram. Large and narrow verification captures additionally retain HLG selected during interaction tests; the final desktop capture is reset to default Adaptive HDR.
- The original source has no fixed upper-right histogram; this is an intentional user-requested change, not fidelity drift. The generated landscape is a new standalone photo matching the alpine golden-hour direction, not a crop of the UI mockup.

## Findings and five fidelity surfaces

- No remaining actionable P0/P1/P2 issues found for the requested desktop demo.
- Typography: system sans-serif stack, restrained small labels and tabular values. Main application title, section titles, control labels and subordinate metadata follow distinct hierarchy. Compact desktop labels intentionally use 10–14px, rather than the much larger typography in the initial image.
- Layout: photo dominates, top primary action remains fixed, inspector top remains at y=62px in 1280×720. Histogram and output summary do not scroll with the parameters. No page-level horizontal overflow at 1280×720 or 390×844. 1440×1024 displays expanded region controls. These density changes implement user feedback.
- Colors: neutral charcoal surfaces, mint primary and selected states, subdued separators. RGB distributions use distinguishable warm/green/blue channels. Decorative glow was removed.
- Assets: generated 1536×1024 photo displays at natural aspect ratio with contain behavior; no stretching. Existing brand asset and licensed Phosphor icon font used. Letterboxing is expected for mismatched photo/viewport ratios.
- Content: labels consistently distinguish SDR interaction preview, AI example parameters, demo versions and actual SDR PNG download. No claim of native HDR or model inference. RAW support is not falsely offered by the local demo file chooser.
- Focused inspection: inspector labels, histogram, three primary slider rows, output summary and export dialog were legible in the original-resolution desktop and export screenshots; no additional magnified region capture was needed.

## Interaction verification

- Brightness arrow adjustment updated +0.60 to +0.65 EV; undo ran and reverted before subsequent actions.
- Split slider accepts keyboard movement; drag uses captured pointer coordinates. Zoom and fit controls exercised.
- RGB/luminance histogram and high-light zebra toggles exercised; sampled pixels and clipping percentages update.
- AI example changed settings and explained that no model runs.
- HLG selection reduced headroom from 2.8 to 2.3 and updated inspector/output summary.
- Demo export reached completion, added version 3, enabled PNG save and updated status.
- JSON and PNG save buttons exercised. Browser download event watcher timed out, but actual files were confirmed under C:/Users/Ryan/Downloads: hyperdr-demo-settings.json (284 bytes, parsed content checked) and HyperDR-demo-SDR.png (3505612 bytes). This was an event-observation limitation, not a failed download.
- Version drawer opened; restoring the natural-light example exercised the restore path.
- File chooser loaded the generated local landscape.png; filename changed and version count became 0.
- Browser console: no warning/error entries in final checked page.
- node --check app.js: passed.

## Comparison history

1. Initial desktop and large captures: no major visual mismatch against the revised brief. Histogram, fixed export and full preview fit as intended.
2. Interaction cleanup: removed an advertised but unimplemented Tab shortcut from focus-mode tooltip; reset service text to ready after edits; hid decorative icon glyphs from accessible names. These did not change composition.
3. Reloaded final implementation and captured preview-desktop.png; confirmed restored initial state and empty console error list.

## Follow-up polish and limits

- P3: desktop helper text is deliberately compact. A larger text preference could be added if desired.
- Drag-drop path is implemented; file chooser path was exercised. No native RAW decoding, production HDR conversion, persistence, model execution or full accessibility certification is claimed.
- Core requested desktop behavior is complete; mobile is a responsive fallback, not a separate mobile product design.

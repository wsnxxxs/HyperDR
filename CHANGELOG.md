# Changelog

All notable user-visible changes to HyperDR are recorded here. The project uses
semantic versioning; dates use ISO 8601.

## Unreleased

- RAW photos can use supported static XMP looks from the local Adobe installation
  on top of their matching DCP. The panel discovers compatible looks; the CLI
  accepts `--raw-look`. Adaptive profiles and unsupported adjustment properties
  are rejected. Profile files are not bundled.

- DCP-based HDR development now keeps above-white scene luminance from the RAW
  instead of deriving every highlight from the clipped SDR rendition. SDR
  development stays unchanged when no XMP look is selected.

- TIFF input supports stripped 8/16-bit RGB and grayscale with embedded ICC
  conversion. `sdr-tiff` exports lossless 16-bit Display P3 TIFF for editing.

- The editor has a 100% detail view using full-resolution decoding and a bounded
  crop, with drag and arrow-key panning. SDR canvas fallback converts P3 pixels
  to sRGB when the browser cannot honor a Display P3 canvas.

- Windows CLI and resident preview requests now use the same UTF-8 path
  handling, fixing previews and profile paths containing Chinese characters.

- Gain-map photographs -- Adaptive HDR HEIC, Ultra HDR JPEG, iPhone HDR HEIC
  in both the ISO and the older Apple format, and gain-map AVIF -- now open with
  both of their own renditions. SDR and JPEG exports use the photograph's
  authored SDR image instead of a tone map of its HDR, and HDR strength scales
  the photograph's own gain, so midtones stay put. Re-exporting to Adaptive HDR
  keeps the authored SDR base exactly wherever one shared gain can reproduce the
  HDR pixel; only other pixels (for example edges of a reduced export) are
  rebuilt, and the report's `adaptive_chroma_loss` says whether any moved.

- The HDR range of a gain-map input is measured from what the photograph
  reaches, not the capacity its metadata declares, so a format with less
  headroom does not dim a photograph that fits: an iPhone frame declaring 3
  stops but peaking at 1.78 exports to HLG (2.3 stops) unchanged.

- An older-format iPhone HDR photo whose MakerNote was removed by an editor
  opens as its SDR image and is reported as degraded
  (`apple_legacy_gain_map_unusable_sdr_fallback`).

- Lowering HDR strength on a PQ/HLG photograph no longer dims diffuse white and
  midtones; compression starts at diffuse white while at least one stop remains.

- For JPEG, PNG and other SDR inputs, brightening now rolls highlights off from
  a fixed 0.48 knee, the same as HDR inputs, and "Expansion start" affects only
  the HDR gain. With the panel's default +0.6 EV, midtones between 0.5 and 0.8
  come out up to about 9% brighter than before, and highlights next to white
  are compressed more firmly. Photographs at zero brightness are unchanged.

- Phone login and certificate setup now retain authentication through
  cross-site browser redirects, fixing `token_required` after opening a valid
  QR link in Chrome.

- Adaptive HEIC gain maps now use high-quality HEVC Q95 compression at their
  existing resolution, replacing lossless coding and its Level 8.5 signalling.
  This adds a small gain-coding error in measured samples; Apple Photos zoom
  compatibility still requires device validation.

- 10-bit Adaptive, PQ, and HLG HEIC exports now use HEVC Main10 signalling
  instead of Range Extensions, avoiding an unnecessary decoder profile
  requirement. Apple Photos zoom behaviour still requires device validation.

- AI enhance no longer fails at the 1280-pixel preview size. Resampling a
  clipped white into the model's input could land one float step above 1.0,
  which the input contract refused, so on a typical desktop window every
  photograph with clipped highlights showed "native model input must be finite
  linear SDR in [0, 1]". Rounding within 1e-5 of the range is now snapped back;
  a base that is genuinely out of range is still refused.

- When an AI preview does fail, the editor returns to the manual adjustment and
  says why. It used to keep "AI 优化" selected and report the enhancement as
  applied over the manual frame it was still showing.

- The desktop editor's header says whether the edit on screen is not exported,
  exported but only in the workspace, or saved, and opens the export window
  from there. An undo that returns to an exported version shows that version
  instead of calling the edit unexported. In the export window, saving becomes
  the primary action once the edit is exported, exporting the same settings
  again becomes secondary, and a disabled export button says why. With the
  "fixed folder" save method, a finished export is saved to that folder
  without a second click.

- The export window's colour choice is "keep wide gamut" or "limit to sRGB".
  It used to call the first option "current gamut" and name the input-fallback
  gamut (sRGB for new sessions) beside it, which read as though the output
  would be sRGB either way. Format cards name their container and main
  property instead of repeating their own title.

- Slider readouts accept typed values (units optional; percentages as
  displayed), strengths read as percentages throughout, and the rows no longer
  carry end-of-scale captions. RAW camera profile and lens correction move into
  a folded "camera & lens" group below the adjustments, so the brightness and
  HDR controls are visible without scrolling. The colour LUT group shows only
  its menu until a look is chosen.

- Viewer: the scroll wheel zooms around the pointer, `+` / `-` step the zoom,
  the zoom buttons disable at their limits, and holding Space compares with the
  original whenever focus is not in a control. Shortcut labels follow the
  platform (Ctrl+O on Windows, ⌘O on macOS).

- Visual refinements: dark-mode primary buttons use a saturated blue fill with
  white text instead of the pale ink colour with navy text; slider tracks,
  disabled text and thumbs are neutral grey rather than slate blue; light-mode
  warning and error text reach 4.5:1 contrast; dialogs share one close icon and
  a short entrance transition; the empty workspace hides the unused histogram,
  and the first photo's load shows its own progress state.

- Original-photo comparison now refreshes its neutral pixels when preview
  resolution increases, keeping detail consistent with the edited image.
  Press-and-hold and split view retain the sharp reference during slider
  drafts instead of resizing a cached low-resolution image.

- Saving a finished export now says what happened. The save action was a plain
  download link inside a modal dialog: the browser took the file and the panel
  said nothing, and the confirmation toast was drawn underneath the dialog that
  raised it, so every message shown while the export dialog was open was
  invisible. Saving now reports progress, the name the file was written under,
  and the reason when it fails -- on the result card, in the export history and
  on the phone -- and toasts are visible above every dialog.

- Where an export is saved is now a preference. The desktop app can write
  straight into a folder picked from its own dialog, either once or as a
  remembered destination, with "open folder" beside the confirmation. Browsers
  that support it get the system "save as" dialog or a remembered directory;
  everywhere else keeps the browser's download folder, which used to be the
  only possibility. The folder belongs to the local desktop app alone: a phone
  on the LAN can neither see nor set it.

- HLG encoding fits saturated highlights into its luminance-dependent signal
  range before applying the transfer function. Directly clipping inverse-OOTF
  channels could darken a bright P3 blue by about 29%; HEIC, AVIF and HLG LUT
  inputs now preserve its luminance while reducing unrepresentable chroma.
- DNG CameraCalibration matrices are applied only when the camera and profile
  calibration signatures match, including their empty defaults. Mismatched
  profiles keep their ColorMatrix/ForwardMatrix without the incompatible
  camera correction, and old decode caches are invalidated.

- RAW colour is converted in float. LibRaw now hands over camera RGB and
  HyperDR applies the camera matrix, so its truncation of up to one code is
  gone and highlights keep colour components above LibRaw's 16-bit output
  ceiling (seen with the clip, unclip and reconstruct highlight modes).
  Colours the camera matrix extrapolates past the spectral locus are
  compressed smoothly into the AP1 gamut instead of being clamped at
  ProPhoto's boundary; the compression leaves colours inside P3 untouched.
  Narrow-band blue lights, which the clamp left nearly black, now render as
  visible blue (in the Sony night frames checked, still darker than the
  camera's own JPEG). Reports record where the matrix came from in
  `raw_color_matrix` (`embedded`, `libraw` or `none`); a camera without one
  is reported as a degraded decode (`no_camera_matrix`), with a warning that
  no longer describes such a degradation as a size mismatch. Earlier decode
  caches are rebuilt.
- Colours fitted into a gamut -- the SDR base, sRGB outputs and the base of an
  HDR photograph's exact gain map -- keep their perceived hue. Reds, oranges,
  yellows and greens now keep their Oklab hue instead of following a straight
  line toward white, which drew pink cores into orange lights; blues and
  violets keep the straight line, where hue models disagree and the Oklab hue
  turned a blue light teal. Colours already inside the gamut are unchanged.
- HLG is read and written with BT.2100's OOTF, which scales a colour by a power
  of its luminance. A gamma on each channel was used before and over-saturated
  every HLG colour: the reference Sony HLG frame now renders 3.1 ΔE ITP
  different on average, almost all of it saturation (median hue change 0.3°),
  and its Adaptive HDR and Ultra HDR exports decode closer to the photograph
  (ΔE ITP mean 2.13 and 4.81, highlights 4.07 and 4.63). HLG LUT spaces use the
  same OOTF.
- HDR files with colours outside Display P3 (Rec.2020 HLG or PQ HEIF and AVIF,
  BT.2100 Ultra HDR) keep those colours until the renderer's gamut fit, which
  keeps their luminance and hue, instead of clamping each channel as they are
  decoded. LUT outputs outside the SDR cube or the HDR headroom are fitted the
  same way.
- DNG colour follows the file's own calibration as the DNG specification
  defines it. LibRaw applied the D65 ColorMatrix under any light; now both
  calibrations are interpolated at the as-shot white, with CameraCalibration,
  AnalogBalance and ForwardMatrix, the way Adobe's DNG SDK reads them.
  Neutrals are unchanged; colours in the seven DNGs checked moved a mean 0.4 to
  3.0 ΔE ITP, more under tungsten light than near daylight for the same camera.
- DNG opcode lists are applied. Phone DNGs (Android, HDR+) carry their lens
  shading correction as OpcodeList2 gain maps, which were ignored, leaving
  corners two to three times too dark and their colour uncorrected; bad
  pixels listed in OpcodeList1 are now fixed as well. A DNG that requires an
  opcode HyperDR does not apply, such as a lens-distortion warp, is reported
  as a degraded decode (`dng_opcode_unsupported`).

- An HDR photograph (HLG/PQ HEIF or AVIF, Ultra HDR, Adaptive HDR) now opens in
  the panel as itself: brightness 0 EV, HDR strength 1.00 and the format's full
  range, instead of the SDR preset's +0.6 EV and 0.4 strength that exported a
  Sony HLG frame 0.6 EV brighter with its 2.3-stop range squeezed to one stop.
  Reset returns an HDR photograph to itself rather than flattening it to SDR, and
  the original-comparison frame is the photograph at those settings. SDR and RAW
  photos keep their existing defaults and reset.
- Adaptive HDR and Ultra HDR exports of an HDR photograph decode back to it pixel
  for pixel. Its gain map is full resolution (a 2048-pixel HEVC grid where a
  single picture would be too large), each pixel's gain restores that pixel, and
  the base keeps the HDR colour. Previously highlights came back about a fifth
  darker on average and saturated highlights desaturated. The declared headroom
  stays the photograph's own. The panel writes such an Adaptive HDR base at 10
  bits, and an Ultra HDR base with a full-resolution map is coded 4:4:4.
- Fixed Adaptive HDR HEIC shadows decoding as black. The base's embedded Display
  P3 ICC profile had a zero slope in its sRGB toe, so every base code under 10
  (and the HDR reconstructed from it) turned black in any reader that honours the
  ICC profile, this converter's own decoder included. All Adaptive HDR exports
  were affected, not only HDR sources.
- `HyperDR verify <output> --reference <source>` reports how far a conversion is
  from its source as a viewer would see it: ΔE ITP (ITU-R BT.2124) mean and
  percentiles by tonal range, PQ PSNR and luminance peaks, at full resolution and
  on 4×4 linear means.

- The AI panel offers three models instead of one: the bundled
  `production-v3` plus two research demonstration options, `research-cnn-v1`
  (image only) and `research-exif-v1` (capture-assisted). The choice lives in a
  dropdown above the AI toggle, survives a refresh with the other workflow
  settings, and is recorded in every export. A model that needs capture settings
  falls back to the image-only model when they are incomplete, keeps the user's
  selection, and says on screen and in the report which model actually ran.
  Reconstruction offsets travel with the model, so a fallback reconstructs with
  the curve it was actually produced from.

- `--ai-model` takes a model id; `model-list --json` reports the table. The
  legacy `embedded` spelling and an omitted value still mean the incumbent, and
  an id this build does not carry is refused by name. `model-gain` gained
  `--input-tensor` and `--capture-json` so an exported network can be compared
  against its framework on the same input.

- Exposure compensation is read from Exif as a signed SRATIONAL and kept with
  its presence, so `0 EV` is a value rather than a missing tag. RAW reads the
  file's own Exif prefix for the capture settings, because LibRaw reports no
  exposure compensation and no presence at all.

- The conversion report moves to schema 9: `model_requested_id` and `model_id`
  are separate, with `model_version`, `model_inference_mode` and
  `model_fallback_reason` beside them, and `settings.ai_model_id` replaces
  `settings.ai_model`.

- HLG/PQ LUTs grade already-developed SDR and HDR endpoints independently;
  identity LUTs preserve both. SDR-style LUTs lift HDR black continuously.
- AI/external LUT grading retains the original gain map and offsets, then
  reconstructs the same HDR pixels for previews and every output format.
- Manual gain-map reports measure peak, headroom utilization and below-knee
  spill after gain quantization and interpolation, before image encoding.

- RAW LUTs transform pixels, black and white levels together. Dark frames and
  bad-pixel maps use original visible-area coordinates before DefaultCrop;
  invalid calibration files fail explicitly. Lens-shading maps preserve those
  coordinates in full and half-size decoding and reserve integer headroom.
- Highlight-mode exposure compensation uses the WB multipliers actually applied
  by LibRaw, including fallback WB. Reports record that selection, stale decode
  caches are invalidated, and the mosaic API rejects non-2x2 CFAs before packing.
- `--raw-gain` is described as a post-decode linear multiplier, matching its
  actual placement and interaction with automatic exposure.

- RAW scene analysis and photographic rendering retain signed linear-P3
  components until gamut compression, preserving saturated colours and their
  luminance. Earlier source-analysis caches are rebuilt.

- Slider drags now show coalesced 640-pixel drafts and refine on release.
  A native preview worker retains decoded sources, manual strength-independent
  preparation, and model predictions. It releases idle resources after 90 seconds.
- Preview delivery sends a float SDR base plus an encoded gain grid for GPU
  reconstruction, and omits an unchanged editor base. Browser diagnostics use
  a bounded native-linear sample; CPU presentation remains available.
- Scene statistics sample a consistent 512-edge spatial reference across render
  sizes. Export reports split codec, verification and publication timings.

- Manual previews use bulk decoded-cache reads and parallel float-packet copies.
  Rebuilding the converter invalidates cached preview frames, and returning to
  a cached slider value also cancels the obsolete render. Gain-grid box filters
  use double-precision sliding windows; gamma search reuses exact decode tables.

- Manual rendering caps broad environment statistics at a 768-pixel grid edge
  while retaining the existing fine grid for highlight gain and edge-aware
  filtering. RAW analysis cache reads use bulk I/O and parallel cell validation.

- RAW preview and conversion requests with a decode cache now reuse source
  luminance samples and gain-cell mean/peak measurements across look changes.
  Analysis entries share the decode cache identity and disk budget; missing
  or truncated entries are rebuilt without changing the rendered pixels.

- Manual rendering reuses bilinear sampling coordinates and local work buffers,
  collects SDR guide luminance with gain requests, and measures quantized gain
  distributions with a 256-bin histogram. Single-channel reconstruction now
  decodes one gain multiplier per pixel and reuses channel metadata.

- RAW gain maps average per-pixel highlight requests so small lights survive
  grid reduction. Gain strength scales the weighted field without normalizing
  its maximum to the whole budget, preserving broad-highlight and noise
  attenuation. RAW base colour no longer changes with HDR strength.

- Manual SDR expansion keeps the same base at every HDR strength, including
  zero, and honours explicit exposure and capture ISO. The panel's HDR strength
  no longer also changes photographic clarity and colour. Broad highlight
  participation is labelled as a weighting rather than a measured area.

- Raster inputs are now identified by their contents rather than by their file
  name. A HEIC exported under a `.jpg` suffix -- which is what a phone gallery
  routinely produces -- used to be handed to the JPEG decoder and rejected for a
  bad marker; it now decodes, and the panel stores it under the extension its
  bytes actually are. Which files are offered at all is still decided by
  extension, so a conversion cannot pick up something that is not an image.
- Fixed the panel refusing valid RAW formats based on an incomplete file-header
  table. RAW extensions now route directly to LibRaw, which is the only layer
  that can distinguish the many TIFF- and ISO-BMFF-based camera formats.
- The list of supported input formats now has one definition, emitted by
  `HyperDR schema` and read by the panel, the native file dialog and the
  browser. It previously existed as five hand-maintained copies.
- Previews of large compressed images are faster: the decoder is told the
  preview bound and stops early instead of producing a full-resolution raster
  that is immediately resampled. A 24 MP JPEG previewed at 2048 px decodes about
  a quarter faster. Exports are unaffected and are byte-identical.
- Each input file is now read once during decoding. A JPEG was previously read
  in full twice -- once only to ask whether it carried a gain map -- and the
  panel read a whole file into memory to inspect its first 32 bytes on every
  upload and every desktop drop.
- The panel accepts a pasted image, says which file it used when several are
  dropped or selected at once, explains a drop it cannot use, and refuses an
  unsupported or oversized file before uploading it rather than after.
- Added HDR input support, so every encoding HyperDR writes it can now also
  read. AVIF joins ARW, DNG, JPEG, PNG, HEIC and HEIF as an input format, and
  BT.2100 PQ and HLG files are decoded through the exact inverse of the transfer
  functions used to write them. 4:2:2 and 4:4:4 chroma are read as well as
  4:2:0, so an HLG 4:2:2 HEIF of the kind Sony's cameras produce converts to any
  of the six outputs with its highlight range intact.
- Added safe Exif import for JPEG, HEIC, AVIF and Ultra HDR inputs. Camera, lens,
  date, capture settings and orientation are carried through without inventing
  fallback Make tags. ISO in particular feeds the gain map's noise weighting.
- Fixed a rotated JPEG reporting its pre-rotation dimensions in the run report
  while the converted image used the rotated ones.
- Fixed 10-bit HEIC and AVIF images whose colour is described only by an ICC
  profile decoding around 64 times too dark.
- Replaced the panel's 8-bit sRGB JPEG preview intermediate with native
  linear-Display-P3 float32 SDR/HDR planes. Preview generation now calls the
  same photographic base, gain-map, and reconstruction code as export; the
  browser performs presentation only. Ultra HDR decode fallback is explicitly
  reported as degraded with `ultrahdr_decode_failed_sdr_fallback` instead of
  silently becoming an ordinary JPEG decode.
- Fixed conversion failing on images whose peak gain does not coincide with
  their brightest pixel. The ISO gain-map reader had begun requiring `gain_max`
  to equal the declared alternate headroom, which are different quantities, and
  because the encoder verifies the file it has just written the conversion
  aborted with an unrelated "failed semantic structure verification" message.
  Files written by 1.0.0 also began reporting as structurally invalid.
- Removed the `neutral` renderer. `--look` now accepts only `photographic`;
  `--look neutral` is rejected rather than silently mapped onto the survivor, so
  a stored preset or script that names it fails loudly. `--contrast`,
  `--vibrance`, `--pop` and `--headroom-max` are no longer silently ignored by a
  second renderer, and the note explaining that has been removed.

## 1.0.0 - 2026-08-06

- Added an explicit mathematical/model preview switch. The first model use
  performs inference, while later comparisons reuse the cached gain map
  instantly until the image or its decode changes.
- Added a model-only optimization-strength control and matched its effect in
  SDR, HDR and exported output without re-enabling mathematical look controls.
- Made the output histogram follow the spatial model gain and optimization
  strength, and removed the mathematical expansion marker in model mode.
- Smoothed model-preview gain sampling to remove visible grid blocks while
  keeping the external `.f32` model path independent from the mathematical
  exposure, tone, contrast and vibrance pipeline.
- Kept PyTorch outside the Windows package; model inference uses the configured
  Python installation and its existing CUDA/PyTorch environment.

## 0.3.2 - 2026-07-31

- Fixed managed HTTPS certificate checks to compare complete SAN IP addresses,
  so a previous address such as `192.168.1.100` cannot be mistaken for the
  current `192.168.1.10`. Certificate setup now also reports and stops on a
  failed private-key permission restriction instead of claiming it succeeded.
- Hardened panel access-token handling: newly generated tokens carry 128 bits
  of entropy, malformed non-ASCII credentials fail normally, and invalid cookie
  credentials share the login throttle without counting requests that supplied
  no credential.
- Fixed percent-encoded upload names being decoded twice.
- Made `thumbnail --quality` reject values outside its documented `1..100`
  range instead of silently clamping them.
- Aligned package and generated-schema version metadata with 0.3.2.

## 0.3.1 - 2026-07-30

- Fixed adjustment-region masks so they refresh when the converter's exact
  curve arrives, stay off the original side of comparison views, and trigger
  only while the matching help question mark is hovered. Slider adjustment now
  remains an unobstructed live preview. The mask uses a lighter diagnostic
  magenta that remains visible over warm highlights.
- Fixed the histogram's brightness/RGB switch never reflecting its active
  state, and strengthened the selected capsule in both themes.
- Reduced mask-rendering overhead by caching the preview's linear luminance and
  reusing its image buffer. The panel labels the mask as an estimate because
  the final export also considers local contrast and noise.
- Fitted the preview frame to the decoded image's real aspect ratio, tightened
  the desktop settings rail, and made the histogram retain a stable readable
  height.

## 0.3.0 - 2026-07-28

- **Breaking.** Replaced the panel's front-end. The rewritten interface that
  was served at `/next` while it was built is now the panel itself, at `/`. The
  previous front-end is gone, and so is the `/next` route: a bookmark to it now
  returns 404 rather than a second copy of the panel. Nothing else about
  running HyperDR changes — the same address, the same access token, the same
  conversion behaviour and the same settings vocabulary.
- Rebuilt the interface as a darkroom: the image is the only lit surface, and
  the masthead, settings rail and output dock float around it as separate cards
  rather than sitting inside one full-width panel.
- Added a wipe comparison that drags between the original and the converted
  render, a result card that names what was written and warns when it has gone
  stale, and a dual-distribution histogram that shows the expansion alongside
  the source.
- Added a mask that shows which pixels a slider is currently acting on, so an
  adjustment that appears to do nothing can be seen to be acting outside the
  visible range rather than being broken.
- Fixed the theme toggle, which showed a sun in dark mode, and made the stored
  choice paint before first render so a reload no longer flashes the wrong
  theme.
- Hardened the panel's async lifecycles: an upload that is replaced mid-flight,
  a preview that returns after its image is dismissed, and a conversion polled
  across a reconnect no longer leave the interface reporting the previous
  image's state.
- Dropped the adjustment presets and the upload/convert/deliver phase strip.
  The presets wrote the same values the sliders already carry, and the phase
  strip repeated what the progress bar beside it was already showing.

## 0.2.2 - 2026-07-27

- Moved the TLS certificate pair to `%LOCALAPPDATA%\HyperDR\tls`, so a release
  archive extracted anywhere keeps serving trusted HTTPS. Earlier versions
  derived the path from the parent of the program directory, which silently
  fell back to HTTP once the folder was moved.
- Added a four-step certificate lookup: command-line arguments, environment
  variables, the managed store, then the pre-0.2.2 `Documents\HyperDR-Cert`
  location, which is copied forward once and never deleted.
- Warned at startup when the certificate has expired or when the current LAN
  address is missing from its subject alternative names, printing the exact
  re-issue command instead of quietly downgrading to HTTP.
- Replaced the one-line HTTP fallback warning with an explanation of every path
  that was searched, and made an explicit `-Certificate`/`-PrivateKey` that
  cannot be honoured exit with a readable message rather than a stack trace.
- Reported an unloadable certificate as a plain-language cause and continued
  over HTTP, where a mismatched key pair previously raised a traceback.
- Added `Setup-HTTPS.bat`, a one-time first-run step that installs `mkcert`
  through winget when needed, creates a certificate authority unique to the
  computer, issues the server certificate, and exports the public root
  certificate to the desktop with both required iPhone trust steps spelled out.
  No authority and no private key is shipped in a release archive.
- Re-issued the managed server certificate automatically, from the same local
  authority, when the router hands the computer a new address or the
  certificate is close to expiry, leaving the phone's installed root untouched.
  A certificate supplied by hand is reported on but never modified.
- Packaged the HTTPS setup and firewall scripts, and documented trusted HTTPS
  in `INSTALL.md` as an install step for true HDR rather than an optional
  extra.

## 0.2.1 - 2026-07-27

- Made browser previews viewport- and pixel-density-aware with bounded
  960/1440/2048 tiers, while keeping the JavaScript CPU renderer capped at
  1280 pixels.
- Added keyboard- and touch-operable 100%/200%/400% preview inspection with
  clamped panning, gesture conflict handling, and HDR-safe canvas scaling.
- Restored the histogram, clipping readouts, and zebra controls on mobile in a
  persistent disclosure, with read-only clipping summaries while collapsed.
- Surfaced the converter's latest log line during a run and stopped indefinite
  polling after a sustained connection failure.
- Consolidated light and dark colour tokens with CSS `light-dark()` and typed
  histogram properties, retaining explicit exceptions for theme icons and
  Canvas blend modes.
- Renamed the packaged Windows launcher to `Start.bat` and simplified the panel
  by removing the command-line copy surface.
- Made the front-end role-contract check understand the dynamically mounted
  quality controls.
- Made release packaging prepare and include the dual Main10/8-bit x265 runtime.
- Added an unpacked-package smoke test covering and self-verifying all six output
  encodings.
- Added the report schema, CLI exit-code documentation, and packaged-release
  quick start.
- Corrected RAW preview, startup protocol, licensing, and dependency
  documentation.

## 0.2.0 - 2026-07-20

- Added Adaptive HDR HEIC, Ultra HDR JPEG/R, PQ/HLG HEIC, and PQ/HLG AVIF
  conversion paths.
- Added the photographic renderer, structured schema-6 reports, resumable
  conversion, and the local browser panel.

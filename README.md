<p align="center">
  <img src=".github/readme/icon.svg" width="104" alt="HyperDR icon">
</p>

<h1 align="center">HyperDR</h1>

<p align="center">
  HDR photo editing, end to end. iPhone · iPad · Mac<br>
  English · <a href="README.zh-CN.md">简体中文</a> · <a href="https://github.com/wsnxxxs/HyperDR/releases">Download for Mac</a> · <a href="CHANGELOG.md">What’s new</a>
</p>

<p align="center">
  <img src=".github/readme/mac-en.png" width="100%" alt="HyperDR on the Mac: the photo on the EDR canvas at left, and the inspector with the histogram, HDR, adjustments and style at right">
</p>

## What it is

HyperDR is a native photo editor for Apple platforms, made for HDR photos. Photos from today’s iPhones and cameras already hold highlights brighter than white, and the screens of Macs, iPhones and iPads can really light them up. Yet most editors flatten the photo into ordinary SDR the moment you touch a slider, and that light is gone. HyperDR keeps it from the camera file all the way to the exported photo, and shows it at your display’s real brightness while you edit.

Above is the Mac app. The photo sits on a Metal EDR canvas, so highlights glow as far as your display allows; the inspector on the right starts with the histogram and waveform, followed by HDR, light and colour, style and the other adjustments. Hold the canvas to see the original at any time, or switch to a split view to compare before and after. The Mac app is native SwiftUI on Apple silicon; the iPhone and iPad apps share the same editing core and render pipeline, with an interface redesigned for touch.

## A CNN that brings HDR back to ordinary photos

Many photos carry no HDR information at all: an ordinary JPEG, an image saved from the web, an old photo from years ago. HyperDR ships a convolutional neural network we trained ourselves for one job: look at an SDR photo and infer how bright its highlights should have been. It was trained on HDR photos rendered by Apple’s own devices and their gain maps, so it learned Apple’s restrained, natural way of lifting highlights rather than simply brightening the whole picture.

The model is small, about 635,000 parameters, and runs on the device through Core ML, so your photo never leaves it. It analyses the photo at a long edge of 1024 pixels and predicts a gain in stops for every 16 × 16 pixel cell, which is then smoothed and scaled up to the full photo. The prediction is a starting point, not a verdict: choose “+ AI” as the HDR source and shape it with strength, range and where the expansion starts. When the photo already has highlights the camera recorded, the AI can add only what the file is missing.

The AI only touches the HDR layer; the SDR picture underneath stays as you graded it. An ordinary screen shows exactly your edit, and an HDR screen lights the highlights the way the model judged. Whatever look or LUT you choose later, the AI keeps inferring from the same development, so a style never pulls it off course.

## LUTs that know their colour space

HyperDR has its own LUT library that imports standard `.cube` files. Unlike many editors, every LUT in it remembers its input and output colour space, and import recognises the common space names in a file name. A LUT that needs an input the photo cannot supply is disabled, instead of being forced onto the photo as if it were sRGB, which would get the colour wrong every time.

Camera Log curves are where most of the care went. LUTs for S-Log3, V-Log, F-Log2, LogC3, LogC4 or Canon Log 3 are written for video footage, so HyperDR develops the RAW photo again in scene-linear light, keeps the file’s own baseline exposure, turns gamut compression off and only then feeds the LUT. Middle grey lands exactly where the curve expects it, and wide-gamut colour reaches the LUT intact, just as it would in a grading application with real footage.

While you pick, every LUT is rendered as a small preview of your own photo. A LUT and the built-in film emulations are alternative looks, and strength mixes in linear light; a look changes colour and the SDR picture while the HDR highlights are kept. The built-in films are Kodak Portra 400, Gold 200, Kodachrome 64, Vision3 500T and Fujifilm Velvia 100, with grain and halation computed from the physical process, and both of those can be used on any photo, with or without a look.

## Frames for showing the work

A finished photo often goes on to be posted, printed or put in a portfolio. HyperDR can add a presentation frame as it exports: Gallery, Label, Story, Hairline and Instant mats, each in five paper tones, with an optional shadow and a caption read from the photo’s own EXIF, such as the camera, lens, aperture and shutter speed.

There is one detail few people notice. In an HDR photo the paper is written with exactly zero gain, so on an HDR display only the photograph lights up, and the mat stays a calm paper white instead of glaring along with it. On the Mac, the Frame panel in the File menu previews the framed photo on a live EDR canvas, and the export looks just like it.

## Other things worth knowing

Preview and export run through the same GPU render graph, built from Core Image and our own Metal kernels in extended-range linear Display P3, so there is no separate export engine reinterpreting your edit. Each file is read back and checked after it is written, before it is handed to Files, Photos or the share sheet.

The preferred output is adaptive HDR: one file holds the SDR picture you graded and an ISO 21496-1 gain map, so an ordinary screen shows the SDR picture and an HDR screen lifts the highlights as far as it can. HyperDR can also write gain-map JPEG, PQ or HLG HEIC and AVIF, and plain JPEG, HEIC and TIFF. Pick what the photo is for, such as the web, social media or Photos, and the format, size and quality are chosen for you.

RAW files are developed by Apple’s CIRAWFilter, and the decoder version is saved with your edit, so opening the photo again, on another device or after an OS update, develops it the same way instead of quietly changing it. HyperDR opens the major RAW formats such as DNG, ARW, CR3, NEF and RAF, as well as HEIC, HIF, AVIF, JPEG, PNG and TIFF. Large files are fine too: 61 MP RAW and 60 MP HIF photos already open, pan at 1:1 and export at full size on iPhone 17 Pro.

HyperDR has no photo library of its own. It reads only the photos you pick in the system picker, and all processing happens on the device. HEIF is read and written by our own container code with HEVC through VideoToolbox, and the app embeds no dynamic libraries and no (L)GPL code.

## Getting and building it

Download the Mac app from [Releases](https://github.com/wsnxxxs/HyperDR/releases), unzip it and move HyperDR.app to Applications. The build is ad-hoc signed and not notarised; if macOS blocks the first launch, choose Open Anyway in System Settings under Privacy & Security. The iPhone and iPad apps are built from source with Xcode for now; see the [installation notes](apps/apple/README-iOS.md). Every version needs iOS or iPadOS 27, or macOS 27 on Apple silicon.

HyperDR 0.5.1 is a pre-release. Full-size 110 MP RAW on iPhone is still being verified, and iOS does not yet continue an export in the background.

To work on it, you need macOS with Xcode, CMake, Ninja, vcpkg and Python 3.12. The SwiftUI apps live in `apps/apple`, the recipe and the GPU render graph in the `HyperDRRecipe` and `HyperDRRender` packages, and the services in `HyperDRKit`. The C++ engine in `modules/` holds the writers, the HEIF reader, the VideoToolbox codecs and export verification, and Swift reaches it only through its C ABI. The AI model’s training code is in `HyperDR_Model`. The usual test commands are:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3.12 scripts/fetch_test_fixtures.py
python3.12 scripts/test.py native --build-dir build   # C++ engine
python3.12 scripts/test.py apple                      # Swift packages, Mac app and localisation check
python3.12 scripts/test.py ios                        # unsigned iPhone and iPad builds
```

## License

HyperDR is dual-licensed under the [GNU AGPL v3.0](LICENSE) or a commercial license; see [LICENSING.md](LICENSING.md). The HyperDR name and app icon are not covered by either license. Third-party components keep their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<p align="center">
  <sub>Copyright © 2026 Renhe Wang</sub>
</p>

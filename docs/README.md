# Documentation

Choose a document by the feature you are working on. User and operator guides
are written in Chinese; development and reference material is written in
English. A document with both audiences follows its primary audience.

## Use a feature

| Goal | Document |
| --- | --- |
| Understand HyperDR and build the converter | [Project README](../README.md) |
| Convert and preview one photo in a browser or on iPhone | [Panel guide](../apps/panel/README.md) |
| Run the Windows desktop application | [Desktop guide](../apps/desktop/README.md) |
| Use the panel from an iPhone over LAN/HTTPS | [iPhone LAN guide](iphone-lan.md) |
| Install an extracted Windows release | [Installation guide](../packaging/INSTALL.md) |
| Enable the optional “优化” model | [Model integration](model-integration.md) |

Folder conversion is a CLI feature; its command and examples are in the
[CLI reference](cli-reference.md).

## Understand behaviour and contracts

| Topic | Document |
| --- | --- |
| Commands, options, exit codes and format behaviour | [CLI reference](cli-reference.md) |
| Supported image formats and Lightroom interchange | [图像格式与 Lightroom 往返](formats.md) |
| Tone, HDR output promises and visual acceptance scenes | [Rendering behaviour](rendering.md) |
| Colour LUT stages, RAW/Log/HLG input spaces and SDR export behaviour | [颜色 LUT 与 SDR/HDR 渲染架构](color-lut-pipeline.md) |
| Conversion report fields | [Report schema guide](report-schema.md) |
| Machine-readable report contract | [schema/report.json](../schema/report.json) |
| Generated settings vocabulary used by the panel | [schema/settings.json](../schema/settings.json) |
| Model dataset, training, evaluation and inference | [Model project guide](../HyperDR_Model/README.md) |

## Develop and release

| Goal | Document |
| --- | --- |
| Find the code that owns a feature | [Project structure](project-structure.md) |
| Iterate and choose proportionate checks | [Development workflow](development.md) |
| Build and smoke-test a Windows release | [Release guide](../packaging/README.md) |
| Understand certificate and local-network boundaries | [Security](../SECURITY.md) |
| Run the macOS gain-map adjudication | [T2 overview](../tests/macos_t2/README.md) and [borrowed-Mac runbook](../tests/macos_t2/RUNBOOK-mac.md) |
| Review user-visible changes by release | [Changelog](../CHANGELOG.md) |

## Archived evidence

`archive/` contains dated, point-in-time evidence: what was seen on a particular
revision, and what was changed in response. It is not maintained as current
feature documentation. Revalidate a finding against the current code before
acting on it, and do not treat a measurement here as a live guarantee.

| Evidence | Status |
| --- | --- |
| [2026-09-24 local Adobe pipeline research](archive/adobe-local-pipeline-research-2026-09-24.md) | Local profiles, model manifests, binary component evidence and TIFF metadata; separates observed data from inferred pipeline behavior. |
| [2026-09-23 HEIF review verification](heif-review-2026-09-23.md) | Separates reproduced HEVC signalling from unverified Apple gain-map compatibility claims. |
| [2026-09-23 gain compression study](gain-compression-study-2026-09-23.md) | Measures full-resolution lossy gain coding separately from downsampling, including decoder signalling. |
| [2026-09-23 WSL gain-map comparison](wsl-gainmap-comparison-2026-09-23.md) | Audits 847 Apple originals and five training-label samples; corrects assumptions about grid and monochrome RExt gain maps. |
| [2026-08-13 panel audit](archive/frontend-panel-2026-08-13/audit.md) | The preview exception was fixed in that report; revalidate its remaining findings against the current UI. |
| [2026-09-06 experience review](archive/experience-review-2026-09-06/) | Four screenshots of the editor as it was that day. No accompanying write-up. |
| [2026-09-06 manual rendering optimization](archive/manual-optimization-2026-09-06.md) | Describes the manual SDR/HDR base unification as delivered on that date. |
| [2026-09-06 interactive pipeline optimization](archive/pipeline-optimization-2026-09-06.md) | Slider coalescing and preview tiers as delivered; the timing numbers are browser presentation, not display scanout. |
| [2026-09-06 RAW pipeline review](archive/raw-pipeline-review-2026-09-06.md) | The six defects it reproduces were fixed; the unimplemented development controls it lists were out of scope. |
| [2026-09-07 zero-adjustment review](archive/zero-adjustment-pipeline-review-2026-09-07.md) | Investigation only, baseline `fbad406`; no product behaviour was changed by it. |
| [2026-09-07 zero-adjustment fix](archive/zero-adjustment-pipeline-fix-2026-09-07.md) | The repair for the review above. No physical HDR display check was performed. |
| [2026-09-07 histogram redesign](archive/histogram-redesign-2026-09-07/README.md) | Screenshots 01–04 are withdrawn proposals; `05-simple-overlay.png` is the shipped overlay. |
| [2026-09-14 research model acceptance](archive/research-model-acceptance.md) | The original delivery record for the three selectable models. Superseded numbers; see the review below. |
| [2026-09-14 research model review](archive/research-model-review.md) | The follow-up review and repair. Its raw evidence lives in machine-local `.workbuddy/` archives that are not part of the repository. |
| [2026-09-20 image pipeline review](archive/image-pipeline-review-2026-09-20.md) | HLG highlight and DNG CameraCalibration defects found and fixed; decode cache schema moved to 14. |
| [2026-09-20 upgrade review](archive/review-2026-09-20.md) | Panel, model-selection and DNG gain-map repairs from the same pass. |
| [2026-09-20 panel interaction plan](archive/panel-interaction-plan-2026-09-20.md) | Why saving a result reported nothing, and the save-destination design that followed. Its P0–P2 shipped. Of the three gaps section four left open, the export button that turned grey without a reason (gap 6) was closed on 2026-09-21; gaps 7 and 8 remain. |

The browser implementation notes in
[apps/panel/web/README.md](../apps/panel/web/README.md) are intentionally kept
beside that code rather than promoted into the user guide.

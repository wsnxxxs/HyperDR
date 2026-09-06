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
| Tone, HDR output promises and visual acceptance scenes | [Rendering behaviour](rendering.md) |
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

`archive/` contains dated, point-in-time evidence. It explains what was seen on
a particular revision and is not maintained as current feature documentation.

| Evidence | Status |
| --- | --- |
| [2026-08-13 panel audit](archive/frontend-panel-2026-08-13/audit.md) | The preview exception was fixed in that report; revalidate its remaining findings against the current UI before acting on them. |

The browser implementation notes in
[apps/panel/web/README.md](../apps/panel/web/README.md) are intentionally kept
beside that code rather than promoted into the user guide.

- [颜色 LUT 与 SDR/HDR 渲染架构](color-lut-pipeline.md) — 接入空间、RAW/Log/HLG 区别、纯 SDR 导出与高光行为。

import AppKit
import SwiftUI

/// The M3 export, history and LUT-library components with fixture values:
/// the acceptance view for this package's M3 components, in the previews
/// below, the gallery snapshots and the app's Developer menu.
///
/// Titles and captions are fixture text (English or Chinese by the
/// environment's locale), not catalogue keys; the words the components say
/// themselves come from the package's own catalogue.
public struct M3ComponentsGallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                formatsColumn
                cardsColumn
                rowsColumn
            }
            .padding(24)
        }
        .background(Color.hdr.surfacePage)
    }

    var formatsColumn: some View { M3FormatsColumn() }
    var cardsColumn: some View { M3CardsColumn() }
    var rowsColumn: some View { M3RowsColumn() }
}

/// Fixture text in the language of the environment's locale.
private struct Words {
    let isChinese: Bool
    init(_ locale: Locale) { isChinese = locale.identifier.hasPrefix("zh") }
    func callAsFunction(_ en: String, _ zh: String) -> String { isChinese ? zh : en }
    func text(_ en: String, _ zh: String) -> Text { Text(verbatim: isChinese ? zh : en) }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Caption(title)
            content
        }
    }
}

@MainActor private enum Thumbnails {
    static func photo() -> Image {
        let renderer = ImageRenderer(content: FixturePhoto().frame(width: 192, height: 128))
        renderer.scale = 2
        return renderer.nsImage.map(Image.init(nsImage:)) ?? Image(systemName: "photo")
    }
}

// MARK: - Formats, toolbar, progress

struct M3FormatsColumn: View {
    @Environment(\.locale) private var locale
    @State private var anyScreen = "iso"
    @State private var hdrOnly = "avif-pq"
    @State private var colorOnly = "jpeg"
    @State private var unavailableSelection = "adaptive"

    var body: some View {
        let w = Words(locale)
        VStack(alignment: .leading, spacing: 22) {
            Section(title: w("Format card: normal, selected, unavailable, selected and unavailable",
                             "格式卡片：普通、选中、不可用、选中且不可用")) {
                HStack(spacing: 8) {
                    FormatCard(name: Text(verbatim: "Adaptive HDR"), detail: w.text("HEIC · SDR-compatible", "HEIC · 兼容 SDR"),
                               isSelected: false, width: 114) {}
                    FormatCard(name: Text(verbatim: "HDR JPEG"), detail: w.text("JPEG · ISO gain map · SDR-compatible", "JPEG · ISO 增益图 · 兼容 SDR"),
                               isSelected: true, width: 114) {}
                }
                HStack(spacing: 8) {
                    FormatCard(name: Text(verbatim: "HEIC PQ"), detail: Text(verbatim: ""), isSelected: false,
                               unavailableReason: w.text("No 10-bit HEVC", "不支持 10 位 HEVC"), width: 114) {}
                    FormatCard(name: Text(verbatim: "HEIC HLG"), detail: Text(verbatim: ""), isSelected: true,
                               unavailableReason: w.text("No HEVC encoder", "没有 HEVC 编码器"), width: 114) {}
                }
                HStack(spacing: 8) {
                    FormatCard(name: Text(verbatim: "AVIF PQ"), detail: w.text("10-bit · for modern browsers", "10 位 · 适合现代浏览器"),
                               isSelected: true, width: 114) {}.disabled(true)
                    FormatCard(name: Text(verbatim: "AVIF HLG"), detail: w.text("10-bit · efficient HDR", "10 位 · 高效 HDR"),
                               isSelected: false, width: 114) {}.disabled(true)
                }
            }
            Section(title: w("Format groups: two columns, four columns, colour only", "格式分组：两列、四列、仅调色")) {
                FormatCardGroup(title: w.text("Works on any screen", "任何屏幕都能看"), items: [
                    FormatCardItem(id: "adaptive", name: Text(verbatim: "Adaptive HDR"), detail: w.text("HEIC · SDR-compatible", "HEIC · 兼容 SDR")),
                    FormatCardItem(id: "iso", name: Text(verbatim: "HDR JPEG"),
                                   detail: w.text("JPEG · ISO gain map · SDR-compatible", "JPEG · ISO 增益图 · 兼容 SDR")),
                ], selection: $anyScreen, columns: 2)
                FormatCardGroup(title: w.text("HDR only · 10-bit", "纯 HDR · 10 位"), items: [
                    FormatCardItem(id: "pq", name: Text(verbatim: "HEIC PQ"), detail: Text(verbatim: ""),
                                   unavailableReason: w.text("No HEVC encoder", "没有 HEVC 编码器")),
                    FormatCardItem(id: "hlg", name: Text(verbatim: "HEIC HLG"), detail: Text(verbatim: ""),
                                   unavailableReason: w.text("No HEVC encoder", "没有 HEVC 编码器")),
                    FormatCardItem(id: "avif-pq", name: Text(verbatim: "AVIF PQ"),
                                   detail: w.text("10-bit · for modern browsers", "10 位 · 适合现代浏览器")),
                    FormatCardItem(id: "avif-hlg", name: Text(verbatim: "AVIF HLG"), detail: w.text("10-bit · efficient HDR", "10 位 · 高效 HDR")),
                ], selection: $hdrOnly, columns: 4)
                FormatCardGroup(title: w.text("Format", "格式"), items: [
                    FormatCardItem(id: "jpeg", name: Text(verbatim: "JPEG"), detail: w.text("8-bit · sRGB or Display P3", "8 位 · sRGB 或 Display P3")),
                    FormatCardItem(id: "tiff", name: w.text("16-bit TIFF", "16 位 TIFF"),
                                   detail: w.text("Lossless · for further editing", "无损 · 适合继续编辑")),
                ], selection: $colorOnly, columns: 2)
                FormatCardGroup(title: w.text("The selected one became unavailable", "已选的格式变成不可用"), items: [
                    FormatCardItem(id: "adaptive", name: Text(verbatim: "Adaptive HDR"), detail: Text(verbatim: ""),
                                   unavailableReason: w.text("No HEVC encoder", "没有 HEVC 编码器")),
                    FormatCardItem(id: "iso", name: Text(verbatim: "HDR JPEG"),
                                   detail: w.text("JPEG · ISO gain map · SDR-compatible", "JPEG · ISO 增益图 · 兼容 SDR")),
                ], selection: $unavailableSelection, columns: 2)
            }
            .frame(width: 480)
            Section(title: w("Toolbar button: Export, Save JPEG, exporting without and with an estimate, can't export",
                             "工具栏按钮：导出、保存 JPEG、导出中（无估计 / 有估计）、不能导出")) {
                HStack(spacing: 8) {
                    ExportToolbarButton(state: .idle(title: w.text("Export", "导出"))) {}
                    ExportToolbarButton(state: .idle(title: w.text("Save JPEG", "保存 JPEG"))) {}
                    ExportToolbarButton(state: .disabled(title: w.text("Export", "导出"),
                                                         reason: w.text("Open a photo first", "请先打开照片"))) {}
                }
                HStack(spacing: 8) {
                    ExportToolbarButton(state: .exporting(fraction: nil)) {}
                    ExportToolbarButton(state: .exporting(fraction: 0.72)) {}
                }
            }
            Section(title: w("Progress bar: known, unknown, past the estimate, stopping", "进度条：已知、未知、超出预计、停止中")) {
                VStack(alignment: .leading, spacing: 12) {
                    ExportProgressBar(progress: .determinate(0.38), height: 8)
                    ExportProgressBar(progress: .indeterminate, height: 8)
                    ExportProgressBar(progress: .overdue, height: 8)
                    ExportProgressBar(progress: .stopped(0.72), height: 8)
                    ExportProgressBar(progress: .determinate(0.72), height: 4)
                }
                .frame(width: 480)
                HStack(spacing: 14) {
                    ForEach([0.0, 0.25, 0.72, 1.0], id: \.self) { value in
                        ProgressRing(fraction: value, size: 20, tint: Color.hdr.accent)
                    }
                    ProgressRing(fraction: nil, size: 20, tint: Color.hdr.accent)
                }
            }
            Section(title: w("Tags and fact rows", "标签与事实行")) {
                HStack(spacing: 6) {
                    HDRTag(w.text("Matches current", "与当前调整一致"), systemImage: "equal", tint: .accent)
                    HDRTag(w.text("Saved", "已保存"), systemImage: "checkmark", tint: .success)
                    HDRTag(w.text("Earlier edit", "上一版的结果"), systemImage: "clock", tint: .warn)
                }
                VStack(alignment: .leading, spacing: 4) {
                    FactRow(label: w.text("Processing", "处理"), value: w.text("HDR · manual", "HDR · 手动"))
                    FactRow(label: w.text("LUT", "LUT"), value: Text(verbatim: "Fuji Classic Chrome (not applied)"), tone: .warn)
                    FactRow(label: w.text("Check", "自检"), value: w.text("Read back and verified", "已回读验证"), tone: .success)
                    FactRow(label: w.text("Size", "尺寸"), value: Text(verbatim: "6000 × 4000 · 18.4 MB"), monospaced: true)
                }
                .frame(width: 240)
            }
        }
        .frame(width: 480, alignment: .leading)
        .background(Color.hdr.surfacePanel)
    }
}

// MARK: - Cards

struct M3CardsColumn: View {
    @Environment(\.locale) private var locale
    @State private var flash = false

    var body: some View {
        let w = Words(locale)
        VStack(alignment: .leading, spacing: 22) {
            Section(title: w("Status card: preparing, estimating, computing, encoding, past the estimate, stopping",
                             "状态卡：准备、估算、计算、编码、超出预计、停止中")) {
                VStack(alignment: .leading, spacing: 10) {
                    statusCard(.running, status: w("Preparing · 0:01 elapsed", "准备中 · 已用 0:01"), progress: .indeterminate)
                    statusCard(.running, status: w("Reading photo · 0:06 elapsed · first export, estimating the time",
                                                   "读取照片 · 已用 0:06 · 首次导出，正在估算所需时间"), progress: .indeterminate)
                    statusCard(.running, status: w("Computing HDR · 0:09 elapsed · about 20 s left",
                                                   "计算 HDR · 已用 0:09 · 约 20 秒后完成"), percent: 0.38)
                    statusCard(.running, status: w("Encoding · 0:21 elapsed · about 10 s left", "编码 · 已用 0:21 · 约 10 秒后完成"),
                               percent: 0.72, emphasis: flash)
                    statusCard(.running, status: w("Encoding · 1:12 elapsed · almost done, a little longer than expected",
                                                   "编码 · 已用 1:12 · 快好了，比预计稍久"), percent: 0.99, progress: .overdue)
                    statusCard(.stopping, status: w("Stopping… · 0:22 elapsed", "正在停止… · 已用 0:22"), percent: 0.72)
                }
                Toggle(isOn: $flash) { Text(verbatim: w("Flash the encoding card", "闪一下“编码”那张卡")) }
                    .toggleStyle(.switch).controlSize(.small).font(.hdr.caption)
            }
            Section(title: w("Status card, ended: saved, not saved, failed", "状态卡，结束：已保存、没有保存、失败")) {
                VStack(alignment: .leading, spacing: 10) {
                    ExportStatusCard(kind: .exported(savedTo: ".../Pictures"), fileName: "DSC04127.jpg",
                                     onDetails: {}, onShowInFinder: {}, onDismiss: {})
                    ExportStatusCard(kind: .saveFailed, fileName: "DSC04127.jpg", onDetails: {}, onSave: {}, onDismiss: {})
                    ExportStatusCard(kind: .failed(title: w.text("Too large for this format", "照片太大，无法存成这种格式")),
                                     fileName: "DSC04127.jpg", onDetails: {}, onDismiss: {})
                }
            }
            Section(title: w("Result card: saved, edited since, saving, not saved", "结果卡：已保存、导出后又调整、正在保存、没有保存")) {
                VStack(alignment: .leading, spacing: 12) {
                    result(w, stale: false, save: .saved(Text(verbatim: w("Saved to .../Pictures", "已保存到 .../图片")), showInFinder: {}))
                    result(w, stale: true, save: .saved(Text(verbatim: w("Saved to .../Pictures", "已保存到 .../图片")), showInFinder: {}))
                    result(w, stale: false, save: .saving)
                    result(w, stale: false, warnings: [w.text("Decoded with reduced precision: the source’s gain map was resampled.",
                                                              "以降低的精度解码：源图的增益图被重新采样。")],
                           save: .failed(w.text("Not saved: HyperDR can’t write to the chosen place. The exported file is kept in Export History.",
                                                "没有保存：HyperDR 无法写入所选位置。导出的文件仍在导出记录里。"), saveAs: {}))
                }
            }
            Section(title: w("Failure card: with details, without", "失败卡：有详细信息、没有")) {
                VStack(alignment: .leading, spacing: 12) {
                    ExportFailureCard(title: w.text("Too large for this format", "照片太大，无法存成这种格式"),
                                      message: w.text("The export is wider or taller than this format’s 65,500-pixel limit, so nothing was exported. Choose HEIC or TIFF, or a smaller frame style, and try again.",
                                                      "导出尺寸超过这种格式每边 65,500 像素的上限，所以没有导出。可以换用 HEIC 或 TIFF，或换一种较小的边框样式后再试。"),
                                      detail: "70144 × 9504 > 65500")
                    ExportFailureCard(title: w.text("Export took too long", "导出超时"),
                                      message: w.text("The export ran for more than an hour and was stopped.", "导出用时超过一小时，已停止。"),
                                      detail: nil)
                }
            }
        }
        .frame(width: Layout.inspectorWidth + 130, alignment: .leading)
        .background(Color.hdr.surfacePanel)
    }

    private func statusCard(_ kind: ExportStatusKind, status: String, percent: Double? = nil, progress: ExportProgressStyle? = nil,
                            emphasis: Bool = false) -> some View {
        ExportStatusCard(kind: kind, fileName: "DSC04127.jpg", statusLine: Text(verbatim: status), percent: percent,
                         progress: progress, emphasis: emphasis, onStop: {}, onDetails: {})
    }

    private func result(_ w: Words, stale: Bool, warnings: [Text] = [], save: ExportSaveRow) -> some View {
        ExportResultCard(thumbnail: Thumbnails.photo(), fileName: "DSC04127.jpg", facts: [
            ExportFact(label: w.text("Size", "尺寸"), value: Text(verbatim: "6000 × 4000 · 18.4 MB"), monospaced: true),
            ExportFact(label: w.text("Peak", "峰值"), value: Text(verbatim: w("5.7× SDR white · +2.5 EV", "SDR 白的 5.7 倍 · +2.5 EV"))),
            ExportFact(label: w.text("Check", "自检"), value: w.text("Read back and verified", "已回读验证"), tone: .success),
            ExportFact(label: w.text("Time", "用时"), value: Text(verbatim: "0:31"), monospaced: true),
        ], warnings: warnings, isStale: stale, saveRow: save)
    }
}

// MARK: - Rows

struct M3RowsColumn: View {
    @Environment(\.locale) private var locale

    var body: some View {
        let w = Words(locale)
        VStack(alignment: .leading, spacing: 22) {
            Section(title: w("History rows: matches current and saved, with a fallback note, not saved, restore disabled",
                             "导出记录行：与当前一致且已保存、带回退说明、未保存、恢复停用")) {
                VStack(spacing: 0) {
                    ExportHistoryRow(
                        thumbnail: Thumbnails.photo(), number: 3, fileName: "DSC04127.jpg",
                        tags: [HDRTag(w.text("Matches current", "与当前调整一致"), systemImage: "equal"),
                               HDRTag(w.text("Saved", "已保存"), systemImage: "checkmark", tint: .accent)],
                        meta: Text(verbatim: w("Today 10:42 · HDR JPEG · 6000 × 4000 · 18.4 MB · manual",
                                               "今天 10:42 · HDR JPEG · 6000 × 4000 · 18.4 MB · 手动")),
                        primary: RowAction(title: w.text("Restore Settings", "恢复这版参数"), isEnabled: false) {},
                        secondary: RowAction(title: w.text("Show in Finder", "在访达中显示"), systemImage: "folder") {})
                    Divider()
                    ExportHistoryRow(
                        thumbnail: Thumbnails.photo(), number: 2, fileName: "DSC04127-ai.heic",
                        tags: [HDRTag(w.text("Saved", "已保存"), systemImage: "checkmark")],
                        meta: Text(verbatim: w("Today 10:31 · Adaptive HDR · 6000 × 4000 · 9.1 MB · AI · Image-only CNN",
                                               "今天 10:31 · Adaptive HDR · 6000 × 4000 · 9.1 MB · AI · 纯 CNN")),
                        note: Text(verbatim: w("Capture data incomplete (aperture); used Image-only CNN",
                                               "拍摄参数不完整（光圈），已使用纯 CNN")),
                        primary: RowAction(title: w.text("Restore Settings", "恢复这版参数")) {},
                        secondary: RowAction(title: w.text("Show in Finder", "在访达中显示"), systemImage: "folder") {})
                    Divider()
                    ExportHistoryRow(
                        thumbnail: Thumbnails.photo(), number: 1, fileName: "DSC04127.jpg",
                        meta: Text(verbatim: w("Today 10:20 · HDR JPEG · 6000 × 4000 · 17.9 MB · manual · this version has a frame",
                                               "今天 10:20 · HDR JPEG · 6000 × 4000 · 17.9 MB · 手动 · 此版带边框")),
                        primary: RowAction(title: w.text("Restore Settings", "恢复这版参数")) {},
                        secondary: RowAction(title: w.text("Save As…", "另存为…"), systemImage: "square.and.arrow.down") {})
                }
                .frame(width: 600)
            }
            Section(title: w("LUT library rows: in use, plain", "LUT 库行：在用、普通")) {
                VStack(spacing: 0) {
                    LUTLibraryRow(name: "Fuji Classic Chrome", spaces: Text(verbatim: "sRGB → sRGB"), size: "1.2 MB", isInUse: true,
                                  onSpaces: {}, onRemove: {})
                    Divider()
                    LUTLibraryRow(name: "Kodak 2383 Print", spaces: Text(verbatim: "Rec. 709 → Rec. 709"), size: "6.1 MB", isInUse: false,
                                  onSpaces: {}, onRemove: {})
                    Divider()
                    LUTLibraryRow(name: "S-Log3 to 709", spaces: Text(verbatim: "S-Log3 · S-Gamut3.Cine → Rec. 709"), size: "2.4 MB",
                                  isInUse: false, onSpaces: {}, onRemove: {})
                }
                .frame(width: 460)
            }
        }
        .frame(width: 600, alignment: .leading)
        .background(Color.hdr.surfacePanel)
    }
}

// MARK: - Previews

#Preview("Light") { M3ComponentsGallery().frame(width: 1700, height: 1400) }

#Preview("Dark") { M3ComponentsGallery().frame(width: 1700, height: 1400).environment(\.colorScheme, .dark) }

#Preview("Chinese, dark") {
    M3ComponentsGallery().frame(width: 1700, height: 1400)
        .environment(\.colorScheme, .dark).environment(\.locale, Locale(identifier: "zh-Hans"))
}

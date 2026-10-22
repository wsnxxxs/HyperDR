import SwiftUI

/// The M2 inspector, scope and canvas components with fixture values: the
/// acceptance view for this package's M2 components, in the previews below,
/// the gallery snapshots and the app's Developer menu.
///
/// Titles and captions are fixture text (English or Chinese by the
/// environment's locale), not catalogue keys; the words the components say
/// themselves come from the package's own catalogue.
public struct M2ComponentsGallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                inspectorColumn.frame(width: Layout.inspectorWidth)
                canvasColumn
            }
            .padding(24)
        }
        .background(Color.hdr.surfacePage)
    }

    var inspectorColumn: some View { M2InspectorColumn() }
    var canvasColumn: some View { M2CanvasColumn() }
}

/// Fixture text in the language of the environment's locale.
private struct Words {
    let isChinese: Bool
    init(_ locale: Locale) { isChinese = locale.identifier.hasPrefix("zh") }
    func callAsFunction(_ en: String, _ zh: String) -> String { isChinese ? zh : en }
    func key(_ en: String, _ zh: String) -> LocalizedStringKey { LocalizedStringKey(isChinese ? zh : en) }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: text).font(.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
    }
}

// MARK: - Inspector column

struct M2InspectorColumn: View {
    @Environment(\.locale) private var locale
    @State private var autoValue = -1.0
    @State private var rangeValue = 2.8
    @State private var strength = 0.4
    @State private var kind = ScopeKind.histogram
    @State private var channels = HistogramChannels.luma
    @State private var highlights = true
    @State private var shadows = false
    @State private var scopeExpanded = true
    @State private var maskShowing = false

    private static let autoSpec = ParameterSpec(range: 0...4, step: 0.1, defaultValue: -1,
                                                format: .number(fractionDigits: 1), automatic: ParameterAutomatic())
    private static let strengthSpec = ParameterSpec(range: 0...1, step: 0.05, defaultValue: 0.4, format: .percent)

    var body: some View {
        let w = Words(locale)
        VStack(alignment: .leading, spacing: 0) {
            section(w("Sliders: Auto", "滑块：自动")) { sliders(w) }
            section(w("Notices", "说明行")) { notices(w) }
            section(w("Section reset", "重置按钮")) { resets(w) }
            section(w("Zebra switches", "斑马纹开关")) { zebras }
            scopes(w)
        }
        .background(Color.hdr.surfacePanel)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Caption(title)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Color.hdr.line).frame(height: 1) }
    }

    private func sliders(_ w: Words) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ParameterSlider(w.key("HDR range · Auto", "HDR 范围 · 自动"), value: .constant(-1), spec: Self.autoSpec)
            ParameterSlider(w.key("HDR range · interactive", "HDR 范围 · 可操作"), value: $autoValue, spec: Self.autoSpec)
            ParameterSlider(w.key("HDR range · 2.8 stops", "HDR 范围 · 2.8 档"), value: $rangeValue,
                            spec: Self.autoSpec, readoutHelp: Text(verbatim: "Limit for this format: 3.0 stops"))
            ParameterSlider(w.key("HDR range · disabled", "HDR 范围 · 停用"), value: .constant(-1), spec: Self.autoSpec)
                .disabled(true)
            ParameterSlider(w.key("Mask mark · idle", "遮罩标记 · 静止"), value: $strength, spec: Self.strengthSpec,
                            mask: ParameterMaskLink(isShowing: false) { _ in })
            ParameterSlider(w.key("Mask mark · showing", "遮罩标记 · 显示中"), value: $strength, spec: Self.strengthSpec,
                            mask: ParameterMaskLink(isShowing: true) { _ in })
            ParameterSlider(w.key("Mask mark · hover to try", "遮罩标记 · 悬停试试"), value: $strength, spec: Self.strengthSpec,
                            mask: ParameterMaskLink(isShowing: maskShowing) { maskShowing = $0 })
        }
    }

    private func notices(_ w: Words) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorNotice(Text(verbatim: w("Switch to the cached AI result", "切换到已缓存的 AI 优化效果")), style: .info)
            InspectorNotice(Text(verbatim: w("Optimizing with AI… Editing is paused until it finishes.",
                                             "AI 优化中…完成前暂停调整。")), style: .progress)
            InspectorNotice(Text(verbatim: w("AI enhancement applied · EXIF-assisted prediction",
                                             "AI 优化已应用 · EXIF 参数辅助预测")), style: .success)
            InspectorNotice(Text(verbatim: w("AI enhancement failed; back to manual: the computation failed",
                                             "AI 优化失败，已切回手动：计算失败")), style: .warning)
        }
    }

    private func resets(_ w: Words) -> some View {
        HStack(spacing: 24) {
            SectionResetButton(w.key("Reset", "重置"), doneTitle: w.key("All reset", "已重置"), isDone: false) {}
            SectionResetButton(w.key("Reset", "重置"), doneTitle: w.key("All reset", "已重置"), isDone: false) {}
                .disabled(true)
            SectionResetButton(w.key("Reset", "重置"), doneTitle: w.key("All reset", "已重置"), isDone: true) {}
        }
    }

    private var zebras: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ZebraSwitch(.highlights, isOn: .constant(false))
                ZebraSwitch(.shadows, isOn: .constant(false))
            }
            HStack(spacing: 6) {
                ZebraSwitch(.highlights, isOn: .constant(true))
                ZebraSwitch(.shadows, isOn: .constant(true))
            }
            HStack(spacing: 6) {
                ZebraSwitch(.highlights, isOn: .constant(false))
                ZebraSwitch(.shadows, isOn: .constant(true))
            }
            .disabled(true)
        }
    }

    @ViewBuilder private func scopes(_ w: Words) -> some View {
        Caption(w("Scope panel", "示波器面板"))
            .padding([.horizontal, .top], 20)
            .padding(.bottom, -8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Color.hdr.line).frame(height: 1) }
        ScopePanel(kind: $kind, channels: $channels, isExpanded: $scopeExpanded, highlightZebra: $highlights,
                   shadowZebra: $shadows, content: .data(M2Fixtures.data), ceilingStops: 2.5)
        Divider()
        ScopePanel(kind: .constant(.histogram), channels: .constant(.rgb), isExpanded: .constant(true),
                   highlightZebra: .constant(false), shadowZebra: .constant(false), content: .data(M2Fixtures.data),
                   ceilingStops: 2.5)
        Divider()
        ScopePanel(kind: .constant(.waveform), channels: .constant(.luma), isExpanded: .constant(true),
                   highlightZebra: .constant(true), shadowZebra: .constant(true), content: .data(M2Fixtures.data),
                   ceilingStops: 0)
        Divider()
        ScopePanel(kind: .constant(.histogram), channels: .constant(.luma), isExpanded: .constant(false),
                   highlightZebra: .constant(false), shadowZebra: .constant(false), content: .data(M2Fixtures.data),
                   ceilingStops: 2.5)
        Divider()
        ScopePanel(kind: .constant(.histogram), channels: .constant(.luma), isExpanded: .constant(true),
                   highlightZebra: .constant(false), shadowZebra: .constant(false), content: .measuring, ceilingStops: nil)
        Divider()
        ScopePanel(kind: .constant(.waveform), channels: .constant(.luma), isExpanded: .constant(true),
                   highlightZebra: .constant(false), shadowZebra: .constant(false), content: .unavailable, ceilingStops: nil)
    }
}

// MARK: - Canvas column

struct M2CanvasColumn: View {
    @Environment(\.locale) private var locale
    @State private var ratio = 0.5

    var body: some View {
        let w = Words(locale)
        VStack(alignment: .leading, spacing: 18) {
            Caption(w("Compare: drag the divider; the legend covers the right side only",
                      "分屏对比：拖动分界线；图例只盖右侧"))
            ZStack(alignment: .topLeading) {
                FixturePhoto()
                SplitOverlay(ratio: ratio, imageFrame: CGRect(x: 0, y: 0, width: 560, height: 340),
                             visibleRect: CGRect(x: 0, y: 0, width: 560, height: 340),
                             originalLabel: Text(verbatim: w("Original", "原图")),
                             editedLabel: Text(verbatim: w("Edited", "调整后")), showsHDRBadge: true,
                             onDrag: { ratio = $0 }, onEditingChanged: { _ in },
                             onNudge: { ratio = min(max(ratio + $0, 0.05), 0.95) })
                CanvasLegend(rows: [.mask(controlName: Text(verbatim: w("HDR expansion strength", "HDR 扩展强度")))])
                    .padding(.leading, 560 * 0.5 + 12).padding(.bottom, 12)
                    .frame(width: 560, height: 340, alignment: .bottomLeading)
            }
            .frame(width: 560, height: 340)
            .clipShape(.rect(cornerRadius: Radius.sm))

            Caption(w("Divider states: rest, hover, dragging, keyboard focus", "分界线状态：静止、悬停、拖动、键盘焦点"))
            HStack(spacing: 14) {
                ForEach([SplitOverlay.HandleState.rest, .hover, .drag, .focus], id: \.self) { state in
                    ZStack {
                        FixturePhoto()
                        SplitOverlay(ratio: 0.5, imageFrame: CGRect(x: 0, y: 0, width: 128, height: 170),
                                     visibleRect: CGRect(x: 0, y: 0, width: 128, height: 170),
                                     originalLabel: Text(verbatim: ""), editedLabel: Text(verbatim: ""),
                                     showsHDRBadge: false, onDrag: { _ in }, onEditingChanged: { _ in },
                                     onNudge: { _ in }, forcedState: state)
                    }
                    .frame(width: 128, height: 170)
                    .clipShape(.rect(cornerRadius: Radius.sm))
                }
            }

            Caption(w("Hints and legends", "提示与图例"))
            HStack(alignment: .bottom, spacing: 18) {
                ZStack(alignment: .bottom) {
                    FixturePhoto()
                    CanvasHint(Text(verbatim: w("Press and hold the photo or Space to see the original",
                                                "按住画面或空格键查看原图")))
                        .padding(16)
                }
                .frame(width: 271, height: 150)
                .clipShape(.rect(cornerRadius: Radius.sm))
                ZStack(alignment: .bottomLeading) {
                    FixturePhoto()
                    CanvasLegend(rows: [.highlightZebra, .shadowZebra]).padding(12)
                }
                .frame(width: 271, height: 150)
                .clipShape(.rect(cornerRadius: Radius.sm))
            }
            ZStack(alignment: .bottom) {
                FixturePhoto()
                CanvasHint(Text(verbatim: w("Drag the divider to compare; with it selected, ← → nudge",
                                            "拖动分界线对比；选中后可用 ← → 微调")))
                    .padding(16)
            }
            .frame(width: 300, height: 120)
            .clipShape(.rect(cornerRadius: Radius.sm))
        }
        .frame(width: 560, alignment: .leading)
    }
}

extension SplitOverlay.HandleState: Hashable {}

// MARK: - Previews

#Preview("Light") { M2ComponentsGallery().frame(width: 1000, height: 1200) }

#Preview("Dark") { M2ComponentsGallery().frame(width: 1000, height: 1200).environment(\.colorScheme, .dark) }

#Preview("Chinese, dark") {
    M2ComponentsGallery().frame(width: 1000, height: 1200)
        .environment(\.colorScheme, .dark).environment(\.locale, Locale(identifier: "zh-Hans"))
}

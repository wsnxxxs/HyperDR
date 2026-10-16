import SwiftUI
import HyperDRDesign

/// The trailing inspector: the histogram on top, then the processing mode and
/// the adjustment groups. Without a photograph it shows the three steps instead.
struct InspectorView: View {
    var workspace: Workspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch workspace {
                case .editing:
                    ScopeSection()
                    Divider()
                    WorkflowSection()
                    Divider()
                    AdjustmentSection()
                    ParameterGroup("作用区域", systemImage: "square.dashed.inset.filled") {
                        ParameterSlider("扩展起点", value: 0.25, in: 0.18...0.75, format: .percent)
                        ParameterSlider("大面积亮部权重", value: 1, in: 0...1, format: .percent)
                        Text("亮度较高的区域优先获得扩展。")
                            .font(Font.hdr.caption)
                            .foregroundStyle(Color.hdr.inkMuted)
                    }
                    ParameterGroup("颜色 LUT", systemImage: "swatchpalette") {
                        LookPicker()
                        ParameterSlider("LUT 强度", value: 1, in: 0...1, format: .percent)
                    }
                    Divider()
                case .empty:
                    Welcome()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.hdr.surfacePanel)
    }
}

// MARK: - Histogram

private struct ScopeSection: View {
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                SectionHeading("直方图")
                Spacer()
                Picker("直方图模式", selection: $mode) {
                    Text("亮度").tag(0)
                    Text("RGB").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            HistogramPlaceholder()
                .frame(height: 132)
            HStack(spacing: Space.s4) {
                Legend(color: Color.hdr.histogramLuma, title: "原图")
                Legend(color: Color.hdr.histogramOutput, title: "调整后")
            }
            VStack(spacing: Space.s1) {
                Capsule().fill(Color.hdr.histogramRamp).frame(height: 4)
                HStack {
                    Text("0")
                    Spacer()
                    Text("SDR 100%")
                    Spacer()
                    Text("+2")
                    Spacer()
                    Text("+4 EV")
                }
                .font(Font.hdr.mono(10))
                .foregroundStyle(Color.hdr.inkMuted)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 16, trailing: 20))
    }
}

/// A fixed curve standing in for the measured distribution: the source as a
/// filled area, the edit as a line that reaches into the HDR range.
private struct HistogramPlaceholder: View {
    var body: some View {
        Canvas { context, size in
            for step in 1..<4 {
                let x = size.width * CGFloat(step) / 4
                context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) },
                               with: .color(Color.hdr.histogramGrid))
            }
            context.fill(curve(in: size, peak: 0.32, spread: 0.16, closed: true), with: .color(Color.hdr.histogramLuma))
            context.stroke(curve(in: size, peak: 0.46, spread: 0.22, closed: false), with: .color(Color.hdr.histogramOutput), lineWidth: 1.5)
        }
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.sm))
        .clipShape(.rect(cornerRadius: Radius.sm))
        .accessibilityLabel("原图分布（填充）与调整后分布（实线）")
    }

    private func curve(in size: CGSize, peak: CGFloat, spread: CGFloat, closed: Bool) -> Path {
        Path { path in
            let samples = 64
            for index in 0...samples {
                let t = CGFloat(index) / CGFloat(samples)
                let bump = exp(-pow((t - peak) / spread, 2)) + 0.35 * exp(-pow((t - 0.8) / 0.08, 2))
                let point = CGPoint(x: t * size.width, y: size.height * (1 - 0.82 * bump))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            if closed {
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                path.closeSubpath()
            }
        }
    }
}

private struct Legend: View {
    var color: Color
    var title: LocalizedStringKey

    var body: some View {
        HStack(spacing: Space.s1 + 2) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title)
        }
        .font(Font.hdr.caption)
        .foregroundStyle(Color.hdr.inkMuted)
    }
}

// MARK: - Mode and adjustments

private struct WorkflowSection: View {
    @State private var hdr = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("处理模式")
            Picker("处理模式", selection: $hdr) {
                Text("仅调色").tag(false)
                Text("HDR 增强").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(hdr ? "增强高光层次，也可以搭配 LUT 调色。" : "套用 LUT、调整光线，保存普通 JPEG。")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
        }
        .padding(20)
    }
}

private struct AdjustmentSection: View {
    @State private var ai = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                SectionHeading("画面调整")
                Spacer()
                Button("重置") {}
                    .buttonStyle(.link)
                    .font(Font.hdr.caption)
                    .help("重置画面调整参数")
            }
            Picker("预览处理方式", selection: $ai) {
                Text("手动调整").tag(false)
                Text("AI 优化").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("先调整整体亮度，再按需增强高光。")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
            ParameterSlider("整体亮度", value: 0, in: -2...2, format: .ev)
            ParameterSlider("HDR 扩展强度", value: 0.4, in: 0...1, format: .percent)
            ParameterSlider("HDR 扩展范围", value: 2.5, in: 0...3, format: .stops)
        }
        .padding(20)
    }
}

/// A collapsible group of parameters under a full-width header.
private struct ParameterGroup<Content: View>: View {
    var title: LocalizedStringKey
    var systemImage: String
    @ViewBuilder var content: Content
    @State private var expanded = true

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        Divider()
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Space.s4) { content }
                .padding(.top, Space.s3)
        } label: {
            Label(title, systemImage: systemImage)
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.ink)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, Space.s3)
    }
}

/// A labelled slider with its value read out on the right.
private struct ParameterSlider: View {
    enum Format { case percent, ev, stops }

    var title: LocalizedStringKey
    var range: ClosedRange<Double>
    var format: Format
    @State private var value: Double

    init(_ title: LocalizedStringKey, value: Double, in range: ClosedRange<Double>, format: Format) {
        self.title = title
        self.range = range
        self.format = format
        _value = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack {
                Text(title)
                    .font(Font.hdr.control)
                    .foregroundStyle(Color.hdr.ink)
                Spacer()
                Text(readout)
                    .font(Font.hdr.readout)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Slider(value: $value, in: range) { Text(title) }
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private var readout: String {
        switch format {
        case .percent: value.formatted(.percent.precision(.fractionLength(0)))
        case .ev: (value >= 0 ? "+" : "") + value.formatted(.number.precision(.fractionLength(2))) + " EV"
        case .stops: value.formatted(.number.precision(.fractionLength(1))) + " EV"
        }
    }
}

private struct LookPicker: View {
    @State private var look = "none"
    @State private var enabled = true

    var body: some View {
        Picker("选择 LUT 风格", selection: $look) {
            Text("不使用 LUT").tag("none")
            Text("Kodak 2383").tag("kodak")
        }
        .labelsHidden()
        Toggle("启用 LUT", isOn: $enabled)
            .font(Font.hdr.control)
    }
}

// MARK: - Empty

private struct Welcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("从一张照片开始")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text("打开照片后，在这里调整光线与高光层次。")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.inkMuted)
                .lineSpacing(5)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 26) {
                Step(number: "01", title: "打开照片", note: "拖入文件，或从本机选择。")
                Step(number: "02", title: "调整光线", note: "手动微调，或使用 AI 优化。")
                Step(number: "03", title: "保存 HDR 照片", note: "导出时选择格式与色域。")
            }
            .padding(.top, Space.s6)
        }
        .padding(EdgeInsets(top: 28, leading: Layout.panelPadding, bottom: 28, trailing: Layout.panelPadding))
    }

    private struct Step: View {
        var number: String
        var title: LocalizedStringKey
        var note: LocalizedStringKey

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(verbatim: number)
                    .font(Font.hdr.mono())
                    .foregroundStyle(Color.hdr.inkMuted)
                    .frame(width: 26, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(.system(size: TypeScale.Size.control, weight: .medium))
                        .foregroundStyle(Color.hdr.ink)
                    Text(note)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                }
            }
        }
    }
}

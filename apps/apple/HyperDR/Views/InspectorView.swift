import SwiftUI
import HyperDRDesign

/// The trailing inspector: the histogram on top, then the photograph's facts,
/// the processing mode and the adjustment groups. Without a photograph it
/// shows the three steps instead.
///
/// M1 renders the photograph without adjustments, so the controls show their
/// defaults and are disabled as a whole (M2 binds them), and the histogram
/// area draws no curve rather than one that is not this photograph's.
struct InspectorView: View {
    let model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.workspace == .editing, let document = model.document {
                    ScopeSection()
                    Divider()
                    PhotoInfoSection(document: document)
                    Divider()
                    adjustments
                        .disabled(true)
                    Divider()
                } else {
                    Welcome()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.hdr.surfacePanel)
    }

    @ViewBuilder private var adjustments: some View {
        WorkflowSection()
        Divider()
        AdjustmentSection()
        ParameterGroup("adjust.region", systemImage: "square.dashed.inset.filled") {
            ParameterSlider("ctrl.expansionStart.label", value: 0.25, in: 0.18...0.75, format: .percent)
            ParameterSlider("ctrl.areaCoverage.label", value: 1, in: 0...1, format: .percent)
            Text("inspector.regionNote")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
        }
        ParameterGroup("lut.title", systemImage: "swatchpalette") {
            LookPicker()
            ParameterSlider("lut.strength", value: 1, in: 0...1, format: .percent)
        }
    }
}

// MARK: - Histogram

private struct ScopeSection: View {
    @State private var mode = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                SectionHeading("editor.histogram")
                Spacer()
                Picker("scope.histMode", selection: $mode) {
                    Text("scope.luma").tag(0)
                    Text("scope.rgb").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(true)
            }
            HistogramFrame()
                .frame(height: 132)
            VStack(spacing: Space.s1) {
                Capsule().fill(Color.hdr.histogramRamp).frame(height: 4)
                HStack {
                    Text(verbatim: "0")
                    Spacer()
                    Text(verbatim: "SDR 100%")
                    Spacer()
                    Text(verbatim: "+2")
                    Spacer()
                    Text(verbatim: "+4 EV")
                }
                .font(Font.hdr.mono(10))
                .foregroundStyle(Color.hdr.inkMuted)
            }
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 16, trailing: 20))
    }
}

/// The plot area with its grid and no data: the histogram is measured from
/// the preview frames in M2 (parity S-01).
private struct HistogramFrame: View {
    var body: some View {
        Canvas { context, size in
            for step in 1..<4 {
                let x = size.width * CGFloat(step) / 4
                context.stroke(Path { $0.move(to: .init(x: x, y: 0)); $0.addLine(to: .init(x: x, y: size.height)) },
                               with: .color(Color.hdr.histogramGrid))
            }
        }
        .overlay {
            Text("mac.scope.unavailable")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
        }
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.sm))
        .clipShape(.rect(cornerRadius: Radius.sm))
    }
}

// MARK: - Photo

/// What M1 knows about the open photograph: the file's own facts, then what
/// the decoder reported with the reference frame. A fact not known yet reads
/// as a dash.
private struct PhotoInfoSection: View {
    let document: DocumentState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("mac.info.title")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                row("mac.info.dimensions", dimensions.map { Text(verbatim: $0) })
                row("mac.info.format", Text(verbatim: document.formatLabel))
                row("mac.info.size", fileSize.map { Text(verbatim: $0) })
                row("mac.info.type", document.source.map { Text($0.domain.label) })
                row("mac.info.color", document.source.map { Text(verbatim: $0.colorName) })
            }
            if let reasons = document.source?.degradationReasons, !reasons.isEmpty {
                Label {
                    Text("mac.info.degraded \(reasons.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.warn)
            }
        }
        .padding(20)
    }

    private func row(_ title: LocalizedStringKey, _ value: Text?) -> some View {
        GridRow {
            Text(title)
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
            (value ?? Text(verbatim: "—"))
                .font(Font.hdr.readout)
                .foregroundStyle(Color.hdr.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var dimensions: String? {
        document.pixelSize.map { "\($0.width) × \($0.height)" }
    }

    private var fileSize: String? {
        document.byteCount > 0 ? document.byteCount.formatted(.byteCount(style: .file)) : nil
    }
}

extension InputDomain {
    /// The photograph's kind as the status bar and inspector name it.
    var label: LocalizedStringKey {
        switch self {
        case .sceneReferred: "stage.input.scene"
        case .sdr: "stage.input.sdr"
        case .hdr: "stage.input.hdr"
        case .dual: "stage.input.dual"
        case .unknown: "stage.input.unknown"
        }
    }
}

// MARK: - Mode and adjustments

private struct WorkflowSection: View {
    @State private var hdr = true

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("workflow.title")
            Picker("workflow.title", selection: $hdr) {
                Text("workflow.color").tag(false)
                Text("workflow.hdr").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(hdr ? "workflow.hdrHint" : "workflow.colorHint")
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
                SectionHeading("inspector.adjustments")
                Spacer()
                // Borderless rather than link: a disabled link keeps its color.
                Button("adjust.reset") {}
                    .buttonStyle(.borderless)
                    .font(Font.hdr.caption)
                    .help("adjust.resetTitle")
            }
            Picker("adjust.mode", selection: $ai) {
                Text("inspector.manual").tag(false)
                Text("adjust.ai").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("inspector.manualNote")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
            ParameterSlider("ctrl.brightness.label", value: 0, in: -2...2, format: .ev)
            ParameterSlider("ctrl.hdrStrength.label", value: 0.4, in: 0...1, format: .percent)
            ParameterSlider("ctrl.hdrRange.label", value: 2.5, in: 0...3, format: .stops)
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
        case .stops: String(localized: "unit.stops \(value.formatted(.number.precision(.fractionLength(1))))")
        }
    }
}

private struct LookPicker: View {
    @State private var look = "none"
    @State private var enabled = true

    // The library's looks are listed once M2 loads it.
    var body: some View {
        Picker("lut.select", selection: $look) {
            Text("lut.none").tag("none")
        }
        .labelsHidden()
        Toggle("lut.enabled", isOn: $enabled)
            .font(Font.hdr.control)
    }
}

// MARK: - Empty

private struct Welcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.title")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text("mac.welcome.description")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.inkMuted)
                .lineSpacing(5)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 26) {
                Step(number: "01", title: "welcome.import", note: "welcome.importNote")
                Step(number: "02", title: "welcome.adjust", note: "welcome.adjustNote")
                Step(number: "03", title: "welcome.export", note: "welcome.exportNote")
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

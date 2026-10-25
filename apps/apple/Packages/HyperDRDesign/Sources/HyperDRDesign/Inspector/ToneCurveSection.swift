import HyperDRRecipe
import SwiftUI

/// The curves a photo can have (adjust-tools §2.1): the luminance curve on
/// both versions, only the SDR base or only the HDR version, and the three
/// colour channels. Each is its own parameter, so each is its own undo step
/// and its own default.
enum CurveChannel: String, CaseIterable, Identifiable, Sendable {
    case luma = "tone.curve"
    case lumaSDR = "tone.curveSDR"
    case lumaHDR = "tone.curveHDR"
    case red = "tone.curveRed"
    case green = "tone.curveGreen"
    case blue = "tone.curveBlue"

    var id: String { rawValue }

    /// The luminance curve and the HDR-only curve carry a segment above SDR white.
    var hasHDRSegment: Bool { self == .luma || self == .lumaHDR }

    /// Only these change the HDR version; with HDR switched off there is none.
    var needsHDR: Bool { self == .lumaHDR }

    var title: Text {
        switch self {
        case .luma: Text("design.curve.channel.luma", bundle: .module)
        case .lumaSDR: Text("design.curve.channel.lumaSDR", bundle: .module)
        case .lumaHDR: Text("design.curve.channel.lumaHDR", bundle: .module)
        case .red: Text("design.curve.channel.red", bundle: .module)
        case .green: Text("design.curve.channel.green", bundle: .module)
        case .blue: Text("design.curve.channel.blue", bundle: .module)
        }
    }

    var tint: ToneCurveTint {
        switch self {
        case .luma, .lumaSDR: ToneCurveTint(sdr: .hdr.accent)
        case .lumaHDR: ToneCurveTint(sdr: .hdr.amber)
        case .red: ToneCurveTint(sdr: .hdr.histogramRed)
        case .green: ToneCurveTint(sdr: .hdr.histogramGreen)
        case .blue: ToneCurveTint(sdr: .hdr.histogramBlue)
        }
    }
}

/// A parameter id, spelled as an `id:` argument so the catalogue check does
/// not take it for a string key (`hdr.range` shares a namespace with keys).
private func parameterID(id: String) -> String { id }
private let hdrEnabledID = parameterID(id: "hdr.enabled")
private let hdrRangeID = parameterID(id: "hdr.range")

/// The ids of the parametric curve (adjust-tools §2.1), zone amounts top to
/// bottom as Lightroom lists them, then the three boundaries.
enum ParametricCurveIDs {
    static let amounts = ["tone.parametricHighlights", "tone.parametricLights", "tone.parametricDarks",
                          "tone.parametricShadows"]
    static let splits = ["tone.parametricSplit1", "tone.parametricSplit2", "tone.parametricSplit3"]
    static var all: [String] { amounts + splits }

    /// Whether this build declares the whole parametric curve.
    static var isDeclared: Bool { all.allSatisfy { Adjustments.declaration($0) != nil } }
}

/// How the host picks a point on the curves from the photograph (the curve
/// eyedropper, adjust-tools §2.2): the user presses on the photo and drags up
/// or down, and the host adds or moves a point at the picked pixel's input.
/// The host owns the sampling and the drag; the section shows the button and
/// marks the picked input on the plot.
public struct CurvePicking {
    /// The photo is waiting for a press.
    public var isActive: Bool
    /// The last picked pixel's place on each curve's input axis, by the
    /// curve's parameter id: 0…1 in the SDR segment, above 1 in the HDR one.
    public var inputs: [String: Double]
    public var toggle: () -> Void
    /// Called with the curve's parameter id the section is showing, whenever
    /// it changes and when picking starts: the curve the drag edits.
    public var select: (String) -> Void

    public init(isActive: Bool, inputs: [String: Double] = [:], toggle: @escaping () -> Void,
                select: @escaping (String) -> Void = { _ in }) {
        self.isActive = isActive
        self.inputs = inputs
        self.toggle = toggle
        self.select = select
    }
}

extension EnvironmentValues {
    /// Set by a host that can sample curve inputs from its canvas. Without
    /// it the curve section has no eyedropper.
    @Entry public var curvePicking: CurvePicking?
}

/// A picking button: the white balance one's twin, for the curves and the
/// colour mixer, named by what it picks.
struct PickToolButton: View {
    let isActive: Bool
    let title: Text
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var touch: Bool { size >= 40 }
    private var radius: CGFloat { touch ? 10 : Radius.xs }

    var body: some View {
        Button(action: action) {
            Image(systemName: "eyedropper")
                .font(.system(size: touch ? 17 : 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(fill, in: .rect(cornerRadius: radius))
                .overlay {
                    if !touch { RoundedRectangle(cornerRadius: radius).strokeBorder(isActive ? Color.clear : Color.hdr.line) }
                }
                .contentShape(.rect(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var fill: Color {
        if isActive { return Color.hdr.accentFill }
        if touch { return Color.white.opacity(0.06) }
        return hovered && isEnabled ? Color.hdr.surfaceHover : Color.clear
    }

    private var foreground: Color {
        if !isEnabled { return Color.hdr.inkDisabled }
        return isActive ? Color.white : hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted
    }
}

/// The "Curve" section of the Light controls: its title, Reset Curve, and
/// under them the curves (adjust-tools §2): a switch between the parameters
/// (four zone sliders over a plot with three draggable boundaries) and the
/// point curves, and for the points a channel menu — luminance on both
/// versions, only SDR, only HDR, red, green, blue. A luminance curve goes on
/// past SDR white into an amber HDR segment as wide as the HDR range. On the
/// Mac it folds away (open while a curve is changed); on the iPad it stays
/// open. Each curve is written as one value, so its undo steps are the
/// editor's drags and single edits.
public struct ToneCurveSection: View {
    @Binding private var recipe: Recipe
    private let control: AdjustmentControl
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void

    @State private var isExpanded: Bool
    @State private var mode: Mode
    @State private var channel = CurveChannel.luma
    @Environment(\.curvePicking) private var picking

    enum Mode: Hashable { case parameters, points }

    public init(recipe: Binding<Recipe>, control: AdjustmentControl, panel: AdjustmentPanel,
                style: AdjustmentControlStyle, onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.control = control
        self.panel = panel
        self.style = style
        self.onEditingChanged = onEditingChanged
        let anyChanged = !control.isDefault
            || (ParametricCurveIDs.isDeclared && ParametricCurveIDs.all.contains { !(panel.control($0, in: recipe.wrappedValue)?.isDefault ?? true) })
        _isExpanded = State(initialValue: style == .touch || anyChanged)
        // Open on the parameters when they are what was edited.
        let parametric = ParametricCurveIDs.amounts.contains { !(panel.control($0, in: recipe.wrappedValue)?.isDefault ?? true) }
        _mode = State(initialValue: parametric && control.isDefault ? .parameters : .points)
    }

    // MARK: State of the curves

    private func isDeclared(_ channel: CurveChannel) -> Bool { Adjustments.declaration(channel.id) != nil }

    private var hdrEnabled: Bool { recipe.conditionValue(hdrEnabledID)?.boolValue ?? true }

    private var availableChannels: [CurveChannel] { CurveChannel.allCases.filter(isDeclared) }

    private var effectiveChannel: CurveChannel {
        availableChannels.contains(channel) && (hdrEnabled || !channel.needsHDR) ? channel : .luma
    }

    private var hasParameters: Bool { ParametricCurveIDs.isDeclared }

    private var effectiveMode: Mode { hasParameters ? mode : .points }

    private func coordinates(_ channel: CurveChannel) -> [Double] {
        if case .curve(let values)? = panel.control(channel.id, in: recipe)?.value { return values }
        return ToneCurve().coordinates
    }

    private func isDefault(_ id: String) -> Bool { panel.control(id, in: recipe)?.isDefault ?? true }

    /// The HDR range the plot's HDR segment is as wide as: the user's, or what
    /// Auto resolves to now.
    private var hdrRange: Double {
        recipe.value(for: hdrRangeID)?.numberValue ?? panel.context.automaticValues[hdrRangeID]
            ?? Adjustments.generatedRangeCeiling
    }

    private func hdrStops(for channel: CurveChannel) -> Double? {
        channel.hasHDRSegment && hdrEnabled ? hdrRange : nil
    }

    private var currentIsDefault: Bool {
        switch effectiveMode {
        case .points: isDefault(effectiveChannel.id)
        case .parameters: ParametricCurveIDs.all.allSatisfy(isDefault)
        }
    }

    private func reset() {
        var edited = recipe
        switch effectiveMode {
        case .points: panel.reset(effectiveChannel.id, in: &edited)
        case .parameters: for id in ParametricCurveIDs.all { panel.reset(id, in: &edited) }
        }
        recipe = edited
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            header
            if isExpanded {
                if hasParameters {
                    SectionSegments(request: SectionSegmentsRequest(
                        title: Text("design.curve.mode", bundle: .module),
                        options: [.init(id: "parameters", title: Text("design.curve.mode.parameters", bundle: .module)),
                                  .init(id: "points", title: Text("design.curve.mode.points", bundle: .module))],
                        selection: Binding(get: { mode == .parameters ? "parameters" : "points" },
                                           set: { mode = $0 == "parameters" ? .parameters : .points })), style: style)
                }
                switch effectiveMode {
                case .points: pointsEditor
                case .parameters: parametricEditor
                }
            }
        }
        .disabled(!control.isAvailable)
        .onChange(of: effectiveChannel) { _, now in picking?.select(now.id) }
        .onChange(of: effectiveMode) { _, now in if now == .parameters, picking?.isActive == true { picking?.toggle() } }
    }

    // MARK: Points

    @ViewBuilder private var pointsEditor: some View {
        let channel = effectiveChannel
        let stops = hdrStops(for: channel)
        if availableChannels.count > 1 || picking != nil {
            HStack(spacing: Space.s2) {
                if availableChannels.count > 1 {
                    Picker(selection: Binding(get: { channel }, set: { self.channel = $0 })) {
                        ForEach(availableChannels) { option in
                            option.title.tag(option)
                                .disabled(option.needsHDR && !hdrEnabled)
                        }
                    } label: {
                        Text("design.curve.channel", bundle: .module)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minHeight: style == .touch ? 44 : nil)
                }
                Spacer(minLength: 0)
                if let picking {
                    PickToolButton(isActive: picking.isActive, title: Text(picking.isActive ? "design.curve.pick.stop" : "design.curve.pick",
                                                                          bundle: .module),
                                   size: style == .touch ? 44 : 22) {
                        picking.select(channel.id)
                        picking.toggle()
                    }
                }
            }
        }
        if let declaration = Adjustments.declaration(channel.id) {
            ToneCurveEditor(coordinates: coordinates(channel), style: style, hdrStops: stops,
                            marker: picking?.inputs[channel.id], tint: channel.tint,
                            write: { panel.set(channel.id, curve: $0, in: &recipe) },
                            onEditingChanged: { onEditingChanged(declaration, $0) })
                .frame(maxWidth: width(hdr: stops != nil))
        }
        Text(style == .touch ? "design.curve.hint.touch" : "design.curve.hint.pointer", bundle: .module)
            .font(Font.hdr.caption)
            .foregroundStyle(Color.hdr.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
    }

    private func width(hdr: Bool) -> CGFloat {
        style == .touch ? (hdr ? 380 : 320) : (hdr ? 292 : 240)
    }

    // MARK: Parameters

    private var preview: ParametricCurvePreview {
        func number(_ id: String) -> Double {
            if case .number(let value)? = panel.control(id, in: recipe)?.value { return value }
            return 0
        }
        // Stored top to bottom as the sliders; the preview goes shadows first.
        return ParametricCurvePreview(amounts: ParametricCurveIDs.amounts.reversed().map(number),
                                      splits: ParametricCurveIDs.splits.map(number))
    }

    private func moveSplit(_ index: Int, to percent: Double) {
        let current = preview.splits
        let moved = ParametricCurvePreview.moved(current, index: index, to: percent)
        guard moved != current else { return }
        panel.set(ParametricCurveIDs.splits[index], number: moved[index], in: &recipe)
    }

    @ViewBuilder private var parametricEditor: some View {
        ParametricCurveEditor(preview: preview, style: style, moveSplit: moveSplit,
                              onEditingChanged: { index, editing in
            if let declaration = Adjustments.declaration(ParametricCurveIDs.splits[index]) {
                onEditingChanged(declaration, editing)
            }
        })
        .frame(maxWidth: width(hdr: false))
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
            ForEach(ParametricCurveIDs.amounts, id: \.self) { id in
                SectionSlider(recipe: $recipe, id: id, panel: panel, style: style, onEditingChanged: onEditingChanged)
            }
        }
        Text("design.curve.parametricHint", bundle: .module)
            .font(Font.hdr.caption)
            .foregroundStyle(Color.hdr.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Space.s2) {
            Button {
                withHDRAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .opacity(style == .touch ? 0 : 1)
                        .frame(width: style == .touch ? 0 : 10)
                    AdjustmentText.label(control.declaration)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkStrong)
                }
                .frame(minHeight: style == .touch ? 44 : 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(style == .touch)
            .accessibilityValue(Text(isExpanded ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
            Spacer(minLength: 0)
            if !currentIsDefault {
                Button(action: reset) {
                    Text("design.curve.reset", bundle: .module)
                        .font(.system(size: TypeScale.Size.caption, weight: .medium))
                        .foregroundStyle(Color.hdr.accent)
                        .frame(minHeight: style == .touch ? 44 : 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

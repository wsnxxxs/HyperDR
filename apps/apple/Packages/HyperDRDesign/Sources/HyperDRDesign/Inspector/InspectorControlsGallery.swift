import SwiftUI

/// The inspector controls in an inspector-wide column, with fixture values:
/// the acceptance view for this package's inspector controls, in the
/// previews below, the gallery snapshots and the app's Developer menu.
///
/// The sliders and curve handles are bound the way the M2 contract has it
/// (batch 3 §3.4): `FixtureModel` stands in for `EditorModel`, with one
/// read-only `FixtureControl` per key, `adjust(_:to:)`, and
/// `beginAdjusting` / `endAdjusting` around drags. The line at the bottom
/// counts undo steps by the contract's rules, so they can be checked by hand.
/// Discrete controls (segments, the switch) keep local state: their API is
/// for batch 4. The labels are fixture text, not catalogue keys, and the
/// curve is a placeholder shape, not the engine's.
public struct InspectorControlsGallery: View {
    @State private var model = FixtureModel()
    @State private var mode = 0
    @State private var regionExpanded = true
    @State private var curveExpanded = true
    @State private var lutExpanded = true
    @State private var cameraExpanded = false
    @State private var lens = 0
    @State private var edge = 1
    @State private var lutEnabled = true

    public init() {}

    public var body: some View {
        ScrollView {
            column.frame(width: Layout.inspectorWidth)
        }
        .frame(width: Layout.inspectorWidth)
        .background(Color.hdr.surfacePanel)
    }

    /// The column without its scroll view, so it can be rendered whole.
    var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionHeading("Adjustments")
                    Spacer()
                    Button("Reset") { model.resetAll() }
                        .buttonStyle(.borderless)
                        .font(.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                }
                ParameterSegmented("Processing mode", selection: $mode, choices: [
                    SegmentedChoice("Manual", value: 0, systemImage: "slider.horizontal.3"),
                    SegmentedChoice("AI optimize", value: 1, systemImage: "sparkles"),
                ])
            }
            .padding([.horizontal, .top], 20)

            VStack(alignment: .leading, spacing: 18) {
                FixtureSlider("Brightness", key: "brightness", model: model, help: "Exposure of the whole photo, in EV.")
                FixtureSlider("HDR strength", key: "strength", model: model)
                FixtureSlider("Contrast", key: "contrast", model: model)
                FixtureSlider("Tint (unavailable)", key: "tint", model: model)
                    .disabled(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            ParameterGroup("Region", systemImage: "circle.lefthalf.filled", isExpanded: $regionExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    FixtureSlider("Participation", key: "participation", model: model)
                    FixtureSlider("Coverage", key: "coverage", model: model)
                    ParameterSegmented("Edge", selection: $edge, choices: [
                        SegmentedChoice("Soft", value: 0),
                        SegmentedChoice("Medium", value: 1),
                        SegmentedChoice("Hard", value: 2),
                        SegmentedChoice("Mask", value: 3, isEnabled: false),
                    ], size: .small)
                }
            }

            ParameterGroup("Gain curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                           summary: Text(verbatim: "Placeholder shape"), isExpanded: $curveExpanded) {
                CurveRows(model: model)
            }

            ParameterGroup("Color LUT", systemImage: "paintpalette", summary: Text(verbatim: "Kodak 2383"),
                           isExpanded: $lutExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Enable LUT", isOn: $lutEnabled).toggleStyle(.hdrSwitch)
                    FixtureSlider("Strength", key: "lutStrength", model: model)
                        .disabled(!lutEnabled)
                }
            }

            ParameterGroup("Camera and lens", systemImage: "camera.aperture", summary: Text(verbatim: "Adobe Standard"),
                           isExpanded: $cameraExpanded) {
                ParameterSegmented("Lens correction", selection: $lens, choices: [
                    SegmentedChoice("Off", value: 0), SegmentedChoice("Auto", value: 1),
                ])
            }

            Rectangle().fill(Color.hdr.line).frame(height: 1)
            FixtureLogView(model: model)
                .padding(20)
        }
        .background(Color.hdr.surfacePanel)
    }
}

// MARK: - Fixtures

/// A stand-in for M2's `ControlValue`: one per key, the same object for the
/// model's lifetime, written only by the model.
@MainActor @Observable final class FixtureControl {
    let key: String
    let spec: ParameterSpec
    fileprivate(set) var value: Double

    init(_ key: String, _ spec: ParameterSpec, _ value: Double) {
        self.key = key
        self.spec = spec
        self.value = value
    }
}

/// A stand-in for `EditorModel`'s control API, counting undo steps by the
/// contract: everything between `beginAdjusting` and `endAdjusting` is one
/// step, none if the value ends where it began; an `adjust` outside them is
/// a step of its own.
@MainActor @Observable final class FixtureModel {
    private(set) var last = "—"
    @ObservationIgnored private var controls: [String: FixtureControl] = [:]
    @ObservationIgnored private var dragStart: [String: Double] = [:]
    @ObservationIgnored private(set) var writes = 0
    @ObservationIgnored private(set) var drags = 0
    @ObservationIgnored private(set) var steps = 0

    init() {
        let specs: [(String, ParameterSpec, Double)] = [
            ("brightness", .signed(-2...2, step: 0.05, format: .signed(fractionDigits: 2, suffix: "EV")), 0.3),
            ("strength", ParameterSpec(range: 0...1, step: 0.05, defaultValue: 0.4, format: .percent), 0.4),
            ("contrast", ParameterSpec(range: 0.8...1.35, step: 0.01, defaultValue: 1, origin: 1,
                                       format: .number(fractionDigits: 2)), 1.12),
            ("tint", .signed(-0.5...0.5, step: 0.01, format: .signed(fractionDigits: 2)), -0.2),
            ("participation", ParameterSpec(range: 0.18...0.75, step: 0.01, defaultValue: 0.25, format: .percent), 0.25),
            ("coverage", ParameterSpec(range: 0...1, step: 0.05, defaultValue: 1, format: .percent), 1),
            ("lutStrength", ParameterSpec(range: 0...1, step: 0.01, defaultValue: 1, format: .percent), 1),
            ("start", ParameterSpec(range: 0...0.75, step: 0.01, defaultValue: 0.35, format: .percent), 0.35),
            ("range", ParameterSpec(range: 0...3, step: 0.1, defaultValue: 2.5, format: .number(fractionDigits: 1)), 2.5),
        ]
        for (key, spec, value) in specs { controls[key] = FixtureControl(key, spec, value) }
    }

    func control(_ key: String) -> FixtureControl { controls[key]! }

    func adjust(_ key: String, to value: Double) {
        let control = control(key)
        guard value != control.value else { return }
        control.value = value
        writes += 1
        if dragStart[key] == nil { steps += 1 }
        report("\(key) = \(control.spec.formatted(value))")
    }

    func beginAdjusting(_ key: String) { dragStart[key] = control(key).value }

    func endAdjusting(_ key: String) {
        guard let start = dragStart.removeValue(forKey: key) else { return }
        drags += 1
        if control(key).value != start { steps += 1 }
        report("\(key) drag end")
    }

    func resetAll() {
        for control in controls.values where control.value != control.spec.defaultValue {
            control.value = control.spec.defaultValue
        }
        steps += 1
        report("reset all")
    }

    private func report(_ event: String) {
        last = "\(event)  ·  writes \(writes), drags \(drags), undo steps \(steps)"
    }
}

private struct FixtureLogView: View {
    let model: FixtureModel

    var body: some View {
        Text(verbatim: model.last)
            .font(.hdr.mono(11))
            .foregroundStyle(Color.hdr.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("gallery.log")
    }
}

/// A slider bound to one control, as M2's inspector rows will be.
private struct FixtureSlider: View {
    let title: String
    let key: String
    let model: FixtureModel
    var help: String?

    init(_ title: String, key: String, model: FixtureModel, help: String? = nil) {
        self.title = title
        self.key = key
        self.model = model
        self.help = help
    }

    var body: some View {
        let control = model.control(key)
        ParameterSlider(LocalizedStringKey(title),
                        value: Binding(get: { control.value }, set: { model.adjust(key, to: $0) }),
                        spec: control.spec, help: help.map { LocalizedStringKey($0) }) { editing in
            editing ? model.beginAdjusting(key) : model.endAdjusting(key)
        }
    }
}

private struct CurveRows: View {
    let model: FixtureModel

    var body: some View {
        let start = model.control("start"), range = model.control("range")
        CurveEditor("Gain curve", samples: Self.placeholder(start: start.value, range: range.value),
                    stopsRange: 0...3, handles: [
            CurveHandle(id: "start", title: "Expansion start", axis: .horizontal,
                        value: Binding(get: { start.value }, set: { model.adjust("start", to: $0) }),
                        spec: start.spec, at: 0),
            CurveHandle(id: "range", title: "HDR range", axis: .vertical,
                        value: Binding(get: { range.value }, set: { model.adjust("range", to: $0) }),
                        spec: range.spec, at: 1),
        ]) { id, editing in editing ? model.beginAdjusting(id) : model.endAdjusting(id) }
    }

    /// A placeholder shape for the gallery only: flat to `start`, then a
    /// smooth rise to `range` stops at SDR white. M2 draws the engine's
    /// `gain_stops` instead.
    static func placeholder(start: Double, range: Double) -> [Double] {
        (0...64).map { i in
            let x = Double(i) / 64
            guard x > start else { return 0 }
            let t = (x - start) / (1 - start)
            return range * t * t * (3 - 2 * t)
        }
    }
}

// MARK: - Previews

#Preview("Light") {
    InspectorControlsGallery().frame(height: 1100)
}

#Preview("Dark") {
    InspectorControlsGallery().frame(height: 1100).environment(\.colorScheme, .dark)
}

#Preview("Increased contrast") {
    InspectorControlsGallery().frame(height: 1100).environment(\._colorSchemeContrast, .increased)
}

#Preview("Increased contrast, dark") {
    InspectorControlsGallery().frame(height: 1100)
        .environment(\.colorScheme, .dark)
        .environment(\._colorSchemeContrast, .increased)
}

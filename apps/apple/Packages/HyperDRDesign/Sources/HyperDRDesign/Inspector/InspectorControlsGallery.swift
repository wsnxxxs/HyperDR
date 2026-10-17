import SwiftUI

/// The inspector controls in an inspector-wide column, with fixture values:
/// the acceptance view for this package's inspector controls, in the
/// previews below, the gallery snapshots and the app's Developer menu.
///
/// The fixtures bind the way S12 recommends for M2: each control owns its
/// value -- local `@State` for most, one `@Observable` object per control
/// for the region group -- and changes go to a sink nobody observes. The
/// labels are fixture text, not catalogue keys, and the curve is a
/// placeholder shape, not the engine's.
public struct InspectorControlsGallery: View {
    @State private var log = GalleryLog()
    @State private var mode = 0
    @State private var regionExpanded = true
    @State private var curveExpanded = true
    @State private var lutExpanded = true
    @State private var cameraExpanded = false
    @State private var lens = 0
    @State private var region = RegionFixture()
    @State private var curve = CurveFixture()
    @State private var lutEnabled = true
    @State private var lutStrength = 1.0

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
                    Button("Reset") { log.record("reset all") }
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
                FixtureSlider("Brightness", log: log, initial: 0.3, help: "Exposure of the whole photo, in EV.",
                              spec: .signed(-2...2, step: 0.05, format: .signed(fractionDigits: 2, suffix: "EV")))
                FixtureSlider("HDR strength", log: log, initial: 0.4,
                              spec: ParameterSpec(range: 0...1, step: 0.05, defaultValue: 0.4, format: .percent))
                FixtureSlider("Contrast", log: log, initial: 1.12,
                              spec: ParameterSpec(range: 0.8...1.35, step: 0.01, defaultValue: 1, origin: 1,
                                                  format: .number(fractionDigits: 2)))
                FixtureSlider("Tint (unavailable)", log: log, initial: -0.2,
                              spec: .signed(-0.5...0.5, step: 0.01, format: .signed(fractionDigits: 2)))
                    .disabled(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)

            ParameterGroup("Region", systemImage: "circle.lefthalf.filled", isExpanded: $regionExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    RegionRows(region: region, log: log)
                    ParameterSegmented("Edge", selection: Bindable(region).edge, choices: [
                        SegmentedChoice("Soft", value: 0),
                        SegmentedChoice("Medium", value: 1),
                        SegmentedChoice("Hard", value: 2),
                        SegmentedChoice("Mask", value: 3, isEnabled: false),
                    ], size: .small)
                }
            }

            ParameterGroup("Gain curve", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                           summary: Text(verbatim: "Placeholder shape"), isExpanded: $curveExpanded) {
                CurveRows(curve: curve, log: log)
            }

            ParameterGroup("Color LUT", systemImage: "paintpalette", summary: Text(verbatim: "Kodak 2383"),
                           isExpanded: $lutExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle("Enable LUT", isOn: $lutEnabled).toggleStyle(.hdrSwitch)
                    ParameterSlider("Strength", value: $lutStrength,
                                    spec: ParameterSpec(range: 0...1, step: 0.01, defaultValue: 1, format: .percent))
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
            GalleryLogView(log: log)
                .padding(20)
        }
        .background(Color.hdr.surfacePanel)
    }
}

// MARK: - Fixtures

/// Where the fixtures' changes go. Nothing in a control reads it, as the
/// model's render channel in S12; only the log line at the bottom does.
@MainActor @Observable final class GalleryLog {
    private(set) var last = "—"
    @ObservationIgnored private(set) var changes = 0
    @ObservationIgnored private(set) var edits = 0

    func change(_ name: String, _ value: String) {
        changes += 1
        last = "\(name) = \(value)  ·  changes \(changes), edits \(edits)"
    }

    func editing(_ name: String, _ editing: Bool) {
        if !editing { edits += 1 }
        last = "\(name) \(editing ? "begin" : "end")  ·  changes \(changes), edits \(edits)"
    }

    func record(_ event: String) { last = event }
}

private struct GalleryLogView: View {
    let log: GalleryLog

    var body: some View {
        Text(verbatim: log.last)
            .font(.hdr.mono(11))
            .foregroundStyle(Color.hdr.inkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("gallery.log")
    }
}

/// A slider owning its value as local state (S12 binding C).
private struct FixtureSlider: View {
    let title: String
    let log: GalleryLog
    let spec: ParameterSpec
    let help: String?
    @State private var value: Double

    init(_ title: String, log: GalleryLog, initial: Double, help: String? = nil, spec: ParameterSpec) {
        self.title = title
        self.log = log
        self.spec = spec
        self.help = help
        _value = State(initialValue: initial)
    }

    var body: some View {
        ParameterSlider(LocalizedStringKey(title), value: $value, spec: spec,
                        help: help.map { LocalizedStringKey($0) }) { log.editing(title, $0) }
            .onChange(of: value) { _, new in log.change(title, spec.formatted(new)) }
    }
}

/// One `@Observable` value per control (S12 binding B).
@MainActor @Observable final class RegionFixture {
    var participation = 0.25
    var coverage = 1.0
    var edge = 1
}

private struct RegionRows: View {
    let region: RegionFixture
    let log: GalleryLog

    var body: some View {
        ParticipationRow(region: region, log: log)
        CoverageRow(region: region, log: log)
    }
}

private struct ParticipationRow: View {
    let region: RegionFixture
    let log: GalleryLog

    var body: some View {
        ParameterSlider("Participation", value: Bindable(region).participation,
                        spec: ParameterSpec(range: 0.18...0.75, step: 0.01, defaultValue: 0.25, format: .percent)) {
            log.editing("Participation", $0)
        }
    }
}

private struct CoverageRow: View {
    let region: RegionFixture
    let log: GalleryLog

    var body: some View {
        ParameterSlider("Coverage", value: Bindable(region).coverage,
                        spec: ParameterSpec(range: 0...1, step: 0.05, defaultValue: 1, format: .percent)) {
            log.editing("Coverage", $0)
        }
    }
}

@MainActor @Observable final class CurveFixture {
    var start = 0.35
    var range = 2.5

    /// A placeholder shape for the gallery only: flat to `start`, then a
    /// smooth rise to `range` stops at SDR white. M2 draws the engine's
    /// `gain_stops` instead.
    var samples: [Double] {
        (0...64).map { i in
            let x = Double(i) / 64
            guard x > start else { return 0 }
            let t = (x - start) / (1 - start)
            return range * t * t * (3 - 2 * t)
        }
    }
}

private struct CurveRows: View {
    let curve: CurveFixture
    let log: GalleryLog

    var body: some View {
        CurveEditor("Gain curve", samples: curve.samples, stopsRange: 0...3, handles: [
            CurveHandle(id: "start", title: "Expansion start", axis: .horizontal, value: Bindable(curve).start,
                        spec: ParameterSpec(range: 0...0.75, step: 0.01, defaultValue: 0.35, format: .percent), at: 0),
            CurveHandle(id: "range", title: "HDR range", axis: .vertical, value: Bindable(curve).range,
                        spec: ParameterSpec(range: 0...3, step: 0.1, defaultValue: 2.5,
                                            format: .number(fractionDigits: 1)), at: 1),
        ]) { id, editing in log.editing(id, editing) }
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

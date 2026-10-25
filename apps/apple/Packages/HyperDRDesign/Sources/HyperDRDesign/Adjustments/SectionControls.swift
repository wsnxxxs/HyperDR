import HyperDRRecipe
import SwiftUI

/// A number slider a section asks its host to draw: the section knows what
/// the slider says and where it writes, the host knows how a slider looks
/// (the Mac inspector's, the iPad Studio's own bars).
public struct SectionSliderRequest {
    public var title: Text
    public var value: Binding<Double>
    public var spec: ParameterSpec
    public var help: Text?
    /// A colour the section would like the slider's fill to take, when the
    /// slider stands for a colour (a mixer band).
    public var tint: Color?
    public var onEditingChanged: (Bool) -> Void
    public var onResetGroup: (() -> Void)?
}

/// A choice among a few segments a section asks its host to draw.
public struct SectionSegmentsRequest {
    public struct Option: Identifiable {
        public var id: String
        public var title: Text
        public var systemImage: String?
        public var isEnabled = true
    }
    public var title: Text
    public var options: [Option]
    public var selection: Binding<String>
}

/// How a host draws the pieces the self-contained sections (curves, colour
/// mixer, colour grading) are made of. Without it a section draws the
/// inspector's own controls, in the pointer or touch style it was given.
public struct SectionControls {
    public var slider: (SectionSliderRequest) -> AnyView
    public var segments: (SectionSegmentsRequest) -> AnyView

    public init(slider: @escaping (SectionSliderRequest) -> AnyView, segments: @escaping (SectionSegmentsRequest) -> AnyView) {
        self.slider = slider
        self.segments = segments
    }
}

extension EnvironmentValues {
    @Entry public var sectionControls: SectionControls?
}

/// One declared number control inside a section: a slider on the id's value,
/// drawn by the host's `SectionControls` when it has them.
struct SectionSlider: View {
    @Binding var recipe: Recipe
    let id: String
    let panel: AdjustmentPanel
    let style: AdjustmentControlStyle
    var title: Text?
    var tint: Color?
    let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    @Environment(\.sectionControls) private var controls

    var body: some View {
        if let control = panel.control(id, in: recipe), let spec = control.spec {
            let declaration = control.declaration
            let request = SectionSliderRequest(
                title: title ?? AdjustmentText.label(declaration),
                value: Binding(get: { control.sliderValue }, set: { panel.set(id, sliderValue: $0, in: &recipe) }),
                spec: spec, help: title == nil ? AdjustmentText.help(declaration) : nil, tint: tint,
                onEditingChanged: { onEditingChanged(declaration, $0) },
                onResetGroup: nil)
            if let controls {
                controls.slider(request)
            } else if style == .touch {
                TouchParameterSlider(request.title, value: request.value, spec: spec, help: request.help,
                                     onEditingChanged: request.onEditingChanged)
            } else {
                ParameterSlider(request.title, value: request.value, spec: spec, help: request.help,
                                onEditingChanged: request.onEditingChanged)
            }
        }
    }
}

/// A choice among a few segments inside a section.
struct SectionSegments: View {
    let request: SectionSegmentsRequest
    let style: AdjustmentControlStyle
    @Environment(\.sectionControls) private var controls

    var body: some View {
        if let controls {
            controls.segments(request)
        } else {
            ParameterSegmented(request.title, selection: request.selection,
                               choices: request.options.map {
                                   SegmentedChoice($0.title, value: $0.id, systemImage: $0.systemImage, isEnabled: $0.isEnabled)
                               })
                .frame(minHeight: style == .touch ? 44 : nil)
        }
    }
}

/// Which section draws a declared control: the controls of a section other
/// than its first are not rows of their own, and the first row is the
/// section itself. The Mac inspector and the iPad panel ask this instead of
/// listing parameters by name.
public enum AdjustmentSections {
    public enum Kind: Sendable { case curves, mixer, grading }

    /// The parameter that stands for each section: where the section is drawn.
    static func anchor(_ kind: Kind) -> String? {
        switch kind {
        case .curves: return CurveChannel.luma.id
        case .mixer: return Adjustments.all.first { $0.id.hasPrefix("hsl.") }?.id
        case .grading: return Adjustments.all.first { $0.id.hasPrefix("grade.") }?.id
        }
    }

    public static func kind(of id: String) -> Kind? {
        if CurveChannel.allCases.contains(where: { $0.id == id }) || ParametricCurveIDs.all.contains(id) { return .curves }
        if id.hasPrefix("hsl.") { return .mixer }
        if id.hasPrefix("grade.") { return .grading }
        return nil
    }

    /// The section a control stands for, when it is the section's anchor.
    public static func section(anchoredBy id: String) -> Kind? {
        guard let kind = kind(of: id), anchor(kind) == id else { return nil }
        return kind
    }

    /// Controls a section draws itself and the generated rows leave out:
    /// all of a section's controls but its anchor.
    public static func isDrawnBySection(_ id: String) -> Bool {
        guard let kind = kind(of: id) else { return false }
        return anchor(kind) != id
    }

    /// Whether the section is the whole of its group, so the group's own
    /// header names it and the section need not.
    public static func fillsItsGroup(_ kind: Kind) -> Bool {
        guard let anchor = anchor(kind), let group = Adjustments.declaration(anchor)?.group else { return false }
        return Adjustments.parameters(in: group).allSatisfy { self.kind(of: $0.id) == kind }
    }
}

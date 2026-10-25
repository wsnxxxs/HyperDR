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
    /// A dot before the title, when the slider stands for a colour (a mixer
    /// band in the by-attribute list).
    public var mark: Color?
    /// Colours the track would show instead of a plain line: a hue control
    /// along the colour circle, a saturation control from grey to the colour.
    public var gradient: [Color]?
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
    /// How a section arranges itself in the room its host gives it.
    @Entry public var sectionLayout: SectionLayout = .stacked
}

/// How the curves, the colour mixer and the grading arrange themselves
/// (controls-polish §9). Stacked, everything runs down one column; split, a
/// host with a wide page of its own (the iPad panel lying along the foot)
/// gets the plot or the wheel on the left and the controls on the right, and
/// the mixer's eight bands in two columns of four.
public enum SectionLayout: Hashable, Sendable {
    case stacked
    case split
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
    var mark: Color?
    var gradient: [Color]?
    let onEditingChanged: (ParameterDeclaration, Bool) -> Void
    @Environment(\.sectionControls) private var controls

    var body: some View {
        if let control = panel.control(id, in: recipe), let spec = control.spec {
            let declaration = control.declaration
            let request = SectionSliderRequest(
                title: title ?? AdjustmentText.label(declaration),
                value: Binding(get: { control.sliderValue }, set: { panel.set(id, sliderValue: $0, in: &recipe) }),
                spec: spec, help: title == nil ? AdjustmentText.help(declaration) : nil, tint: tint, mark: mark, gradient: gradient,
                onEditingChanged: { onEditingChanged(declaration, $0) },
                onResetGroup: nil)
            if let controls {
                controls.slider(request)
            } else if style == .touch {
                TouchParameterSlider(request.title, value: request.value, spec: spec, help: request.help,
                                     onEditingChanged: request.onEditingChanged)
                    .environment(\.sliderTrackGradient, gradient)
            } else {
                ParameterSlider(request.title, value: request.value, spec: spec, help: request.help,
                                onEditingChanged: request.onEditingChanged)
                    .environment(\.sliderTrackGradient, gradient)
                    .environment(\.parameterSliderLayout, .inline(titleWidth: SectionMetrics.titleWidth))
                    .environment(\.parameterSliderMark, mark)
            }
        }
    }
}

/// Sizes the sections share.
enum SectionMetrics {
    /// The title column of an inline slider in a section.
    static let titleWidth: CGFloat = 64
}

/// A section's title row (controls-polish §2.1): on the Mac a disclosure with
/// the title, a dot when anything in it is changed and, folded, a summary;
/// then the section's tools (the eyedropper) and ↺, which resets the section
/// and is there only when there is something to reset. On touch it does not
/// fold, and the title can be left to the host (the iPad's sub-page names it).
struct SubsectionHeader<Tools: View>: View {
    let title: Text
    let style: AdjustmentControlStyle
    var showsTitle = true
    let isChanged: Bool
    /// Whether ↺ has something to reset, when it resets less than the whole
    /// section (the curve shown); otherwise `isChanged`.
    var canReset: Bool?
    var summary: Text?
    /// Nil when the section does not fold.
    var isExpanded: Binding<Bool>?
    let resetLabel: Text
    let reset: () -> Void
    @ViewBuilder var tools: Tools

    private var touch: Bool { style == .touch }

    var body: some View {
        HStack(spacing: Space.s2) {
            if showsTitle { titleButton }
            Spacer(minLength: 0)
            tools
            if canReset ?? isChanged {
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: touch ? 15 : 11, weight: .semibold))
                        .frame(width: touch ? 44 : 22, height: touch ? 44 : 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.hdr.inkMuted)
                .help(resetLabel)
                .accessibilityLabel(resetLabel)
                .transition(.opacity)
            }
        }
        .frame(minHeight: touch ? 44 : 24)
        // On the Mac a hairline sets a section apart from the group's own rows.
        .padding(.top, touch || !showsTitle ? 0 : Space.s2)
        .overlay(alignment: .top) {
            if !touch, showsTitle { Rectangle().fill(Color.hdr.line).frame(height: 1) }
        }
        .animation(.smooth(duration: 0.15), value: canReset ?? isChanged)
    }

    @ViewBuilder private var titleButton: some View {
        let label = HStack(spacing: Space.s1) {
            if !touch, isExpanded != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.hdr.inkMuted)
                    .rotationEffect(.degrees(isExpanded?.wrappedValue == true ? 90 : 0))
                    .frame(width: 10)
            }
            title
                .font(touch ? .subheadline.weight(.semibold) : .system(size: TypeScale.Size.caption, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
                .lineLimit(1)
            if isChanged {
                Circle().fill(Color.hdr.accent).frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            if let summary, isExpanded?.wrappedValue == false {
                summary
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hdr.inkMuted)
                    .lineLimit(1)
            }
        }
        if let isExpanded, !touch {
            Button {
                withHDRAnimation { isExpanded.wrappedValue.toggle() }
            } label: {
                label.frame(minHeight: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isExpanded.wrappedValue ? "design.group.expanded" : "design.group.collapsed", bundle: .module))
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }
}

/// What a folded section says it holds.
enum SectionSummary {
    static func changes(_ count: Int) -> Text? {
        count > 0 ? Text("design.section.changes \(String(count))", bundle: .module) : nil
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

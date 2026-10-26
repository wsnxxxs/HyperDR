import HyperDRRecipe
import SwiftUI

/// The eight colour zones of the mixer (adjust-tools §6.1), named and in the
/// order Lightroom lists them. Ids are the declared `hsl.<band>.<attribute>`.
public enum MixerBand: String, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    public var id: String { rawValue }

    /// Where the zone sits on the colour circle, in turns: only for the
    /// swatch that stands for it.
    var turns: Double {
        switch self {
        case .red: 0.0
        case .orange: 0.075
        case .yellow: 0.15
        case .green: 0.33
        case .aqua: 0.5
        case .blue: 0.6
        case .purple: 0.75
        case .magenta: 0.88
        }
    }

    /// The swatch colour. These stand for data (which colour a slider moves),
    /// not for the interface, as the histogram's channel colours do.
    public var swatch: Color { Color(hue: turns, saturation: 0.72, brightness: 0.95) }

    public var title: Text {
        switch self {
        case .red: Text("design.mixer.band.red", bundle: .module)
        case .orange: Text("design.mixer.band.orange", bundle: .module)
        case .yellow: Text("design.mixer.band.yellow", bundle: .module)
        case .green: Text("design.mixer.band.green", bundle: .module)
        case .aqua: Text("design.mixer.band.aqua", bundle: .module)
        case .blue: Text("design.mixer.band.blue", bundle: .module)
        case .purple: Text("design.mixer.band.purple", bundle: .module)
        case .magenta: Text("design.mixer.band.magenta", bundle: .module)
        }
    }

    public func id(_ attribute: MixerAttribute) -> String { "hsl.\(rawValue).\(attribute.rawValue)" }

    /// What the track of an attribute shows: the hue runs between the
    /// neighbouring colours, the saturation from grey to the zone's colour.
    func gradient(_ attribute: MixerAttribute) -> [Color]? {
        switch attribute {
        case .hue: TrackGradient.shift(of: self)
        case .saturation: TrackGradient.saturation(toward: swatch)
        case .luminance: nil
        }
    }
}

/// What the mixer moves in a zone.
public enum MixerAttribute: String, CaseIterable, Identifiable, Sendable {
    case hue, saturation, luminance

    public var id: String { rawValue }

    public var title: Text {
        switch self {
        case .hue: Text("design.mixer.attribute.hue", bundle: .module)
        case .saturation: Text("design.mixer.attribute.saturation", bundle: .module)
        case .luminance: Text("design.mixer.attribute.luminance", bundle: .module)
        }
    }
}

/// How the host adjusts the mixer from the photograph (adjust-tools §6.3): the
/// user presses a colour on the photo and drags up or down, and the host
/// adds the drag to the chosen attribute of the zones that colour belongs to,
/// as one undo step. The host owns the sampling and the drag; the section
/// shows the button and tells the host which attribute is being adjusted.
public struct MixerPicking {
    public var isActive: Bool
    public var toggle: () -> Void
    /// Called with the attribute the section is showing, whenever it
    /// changes and when picking starts.
    public var setAttribute: (MixerAttribute) -> Void

    public init(isActive: Bool, toggle: @escaping () -> Void, setAttribute: @escaping (MixerAttribute) -> Void) {
        self.isActive = isActive
        self.toggle = toggle
        self.setAttribute = setAttribute
    }
}

extension EnvironmentValues {
    /// Set by a host that can sample colour from its canvas. Without it the
    /// mixer has no eyedropper.
    @Entry public var mixerPicking: MixerPicking?
}

/// The colour mixer (adjust-tools §6): eight colour zones, each with a hue,
/// saturation and brightness shift, one control per declared parameter. The
/// section only wires the declarations to `ColorMixerLayout`, which arranges
/// them; nothing here is stored.
public struct ColorMixerSection: View {
    @Binding private var recipe: Recipe
    private let panel: AdjustmentPanel
    private let style: AdjustmentControlStyle
    private let showsTitle: Bool
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void

    public init(recipe: Binding<Recipe>, panel: AdjustmentPanel, style: AdjustmentControlStyle,
                showsTitle: Bool = true, onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.panel = panel
        self.style = style
        self.showsTitle = showsTitle
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        ColorMixerLayout(style: style, showsTitle: showsTitle,
                         isChanged: { !(panel.control($0, in: recipe)?.isDefault ?? true) },
                         resetAll: {
            var edited = recipe
            for id in ColorMixerLayout<EmptyView>.ids { panel.reset(id, in: &edited) }
            recipe = edited
        }, slider: { id, title, tint, mark, gradient in
            SectionSlider(recipe: $recipe, id: id, panel: panel, style: style, title: title, tint: tint, mark: mark,
                          gradient: gradient, onEditingChanged: onEditingChanged)
        })
    }
}

/// Lightroom's two ways of reading the mixer, one at a time: by attribute
/// (pick hue, saturation or brightness, and see eight sliders, one per zone)
/// or by colour (pick a zone, and see its three sliders). The eyedropper
/// works from the photograph on the attribute shown. The sliders are the
/// caller's, by parameter id, so a preview can fill them with made-up values.
struct ColorMixerLayout<Slider: View>: View {
    let style: AdjustmentControlStyle
    let showsTitle: Bool
    let isChanged: (String) -> Bool
    let resetAll: () -> Void
    /// `mark` is the dot before a band's name in the by-attribute list.
    @ViewBuilder let slider: (_ id: String, _ title: Text, _ tint: Color, _ mark: Color?, _ gradient: [Color]?) -> Slider

    /// Open or folded while the host keeps no record of it (`openSections`).
    @State private var ownExpanded: Bool
    @Environment(\.openSections) private var openSections
    @State private var arrangement: Arrangement
    @State private var attribute = MixerAttribute.hue
    @State private var band = MixerBand.red
    @Environment(\.mixerPicking) private var picking
    @Environment(\.sectionLayout) private var layout

    enum Arrangement: String { case attribute, band }

    init(style: AdjustmentControlStyle, showsTitle: Bool, isChanged: @escaping (String) -> Bool,
         resetAll: @escaping () -> Void, initialArrangement: Arrangement = .attribute,
         @ViewBuilder slider: @escaping (_ id: String, _ title: Text, _ tint: Color, _ mark: Color?, _ gradient: [Color]?) -> Slider) {
        self.style = style
        self.showsTitle = showsTitle
        self.isChanged = isChanged
        self.resetAll = resetAll
        self.slider = slider
        _arrangement = State(initialValue: initialArrangement)
        _ownExpanded = State(initialValue: style == .touch || !showsTitle || Self.ids.contains(where: isChanged))
    }

    /// Open or folded: the host's record when it keeps one (the Mac
    /// inspector's), otherwise this section's own.
    private var expansion: Binding<Bool> {
        SectionDisclosure.binding(.mixer, style: style, showsTitle: showsTitle, open: openSections, own: $ownExpanded)
    }

    private var isExpanded: Bool { expansion.wrappedValue }

    static var ids: [String] { MixerBand.allCases.flatMap { band in MixerAttribute.allCases.map(band.id) } }

    private func isChanged(band: MixerBand) -> Bool { MixerAttribute.allCases.contains { isChanged(band.id($0)) } }

    private var anyChanged: Bool { Self.ids.contains(where: isChanged) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if showsTitle { header }
            if isExpanded || !showsTitle {
                if showsTitle {
                    arrangementChoice
                } else if layout == .split {
                    // The page names the section: its tools stand beside the choice.
                    HStack(spacing: Space.s2) {
                        arrangementChoice
                        header.fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    // A narrow page (the iPad's side panel): the tools above, so the
                    // four choices have the whole width for their names.
                    header
                    arrangementChoice
                }
                if picking?.isActive == true {
                    Text("design.mixer.pickHint", bundle: .module)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch arrangement {
                case .attribute: byAttribute
                case .band: byBand
                }
            }
        }
        .onChange(of: attribute) { _, now in picking?.setAttribute(now) }
        .onChange(of: arrangement) { _, now in
            switch now {
            case .attribute: picking?.setAttribute(attribute)
            // The eyedropper belongs to the by-attribute view: leaving it ends the pick.
            case .band: if picking?.isActive == true { picking?.toggle() }
            }
        }
        // And to the section on screen: a page or tool left ends the pick.
        .onDisappear { if picking?.isActive == true { picking?.toggle() } }
        // Folding the section hides the eyedropper's button: it ends the pick too.
        .onChange(of: isExpanded) { _, open in if !open, picking?.isActive == true { picking?.toggle() } }
    }

    private var header: some View {
        SubsectionHeader(title: Text("design.mixer.title", bundle: .module), style: style, showsTitle: showsTitle,
                         isChanged: anyChanged, summary: SectionSummary.changes(Self.ids.filter(isChanged).count),
                         isExpanded: showsTitle && style == .pointer ? expansion : nil,
                         resetLabel: Text("design.mixer.reset", bundle: .module), reset: resetAll) {
            if let picking, isExpanded || !showsTitle {
                PickToolButton.mixer(isActive: picking.isActive, size: style == .touch ? 44 : 22) {
                    picking.setAttribute(attribute)
                    picking.toggle()
                }
                // It adjusts the attribute shown; one band's three have none.
                .disabled(arrangement == .band)
            }
        }
    }

    /// One choice: an attribute across the eight bands, or one band's three.
    private var arrangementChoice: some View {
        SectionSegments(request: SectionSegmentsRequest(
            title: Text("design.mixer.arrangement", bundle: .module),
            options: MixerAttribute.allCases.map { .init(id: $0.rawValue, title: $0.title) }
                + [.init(id: Arrangement.band.rawValue, title: Text("design.mixer.arrangement.band", bundle: .module))],
            selection: Binding(get: { arrangement == .band ? Arrangement.band.rawValue : attribute.rawValue },
                               set: { id in
                                   if let chosen = MixerAttribute(rawValue: id) {
                                       attribute = chosen
                                       arrangement = .attribute
                                   } else {
                                       arrangement = .band
                                   }
                               })), style: style)
    }

    // MARK: Arrangements

    @ViewBuilder private var byAttribute: some View {
        let spacing = style == .touch ? Space.s2 : Space.s1
        switch layout {
        case .stacked:
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(MixerBand.allCases) { band in row(band) }
            }
        case .split:
            // Two columns of four, the warm bands down the first.
            let half = (MixerBand.allCases.count + 1) / 2
            HStack(alignment: .top, spacing: Space.s4) {
                ForEach([Array(MixerBand.allCases.prefix(half)), Array(MixerBand.allCases.dropFirst(half))], id: \.self) { column in
                    VStack(alignment: .leading, spacing: spacing) {
                        ForEach(column) { band in row(band) }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func row(_ band: MixerBand) -> Slider {
        slider(band.id(attribute), band.title, band.swatch, band.swatch, band.gradient(attribute))
    }

    private var byBand: some View {
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s1) {
            swatches
            ForEach(MixerAttribute.allCases) { attribute in
                slider(band.id(attribute), attribute.title, band.swatch, nil, band.gradient(attribute))
            }
        }
    }

    /// The eight zones as dots to pick from; a dot that has changes carries a mark.
    private var swatches: some View {
        let side: CGFloat = style == .touch ? 30 : 18
        return HStack(spacing: 0) {
            ForEach(MixerBand.allCases) { option in
                Button { band = option } label: {
                    Circle()
                        .fill(option.swatch)
                        .frame(width: side, height: side)
                        .overlay {
                            Circle().strokeBorder(Color.hdr.inkStrong, lineWidth: band == option ? 2 : 0).padding(-3)
                        }
                        .overlay(alignment: .bottom) {
                            if isChanged(band: option) {
                                Circle().fill(Color.hdr.inkStrong).frame(width: 4, height: 4).offset(y: 8)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: style == .touch ? 44 : 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(band == option ? .isSelected : [])
            }
        }
    }

}

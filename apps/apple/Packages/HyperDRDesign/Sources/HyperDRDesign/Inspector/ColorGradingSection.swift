import HyperDRRecipe
import SwiftUI

/// The tonal zones of the colour grading (adjust-tools §7): the three ranges
/// of lightness and the whole photo. Ids are the declared
/// `grade.<zone>.hue|saturation|luminance`.
public enum WheelZone: String, CaseIterable, Identifiable, Sendable {
    case shadows, midtones, highlights, global

    public var id: String { rawValue }

    public var title: Text {
        switch self {
        case .shadows: Text("design.grade.zone.shadows", bundle: .module)
        case .midtones: Text("design.grade.zone.midtones", bundle: .module)
        case .highlights: Text("design.grade.zone.highlights", bundle: .module)
        case .global: Text("design.grade.zone.global", bundle: .module)
        }
    }

    public var hueID: String { "grade.\(rawValue).hue" }
    public var saturationID: String { "grade.\(rawValue).saturation" }
    public var luminanceID: String { "grade.\(rawValue).luminance" }

    public static let blendingID = "grade.blending"
    public static let balanceID = "grade.balance"
}

/// The wheel's geometry, apart from any view: where a hue and a saturation
/// sit on the disc, and which they are for a point on it. Hue runs clockwise
/// from the right (the angular gradient's own start), saturation from the
/// centre (0) to the rim (100).
enum GradingWheelMath {
    /// What the grading makes of mid grey for a hue (the recipe's degrees) and a
    /// saturation (0…100): the shader's own result, so a swatch is the colour
    /// the photo takes.
    static func colour(hue: Double, saturation: Double) -> Color {
        let rgb = GradingColor.displayRGB(hue: hue, saturation: saturation)
        return Color(.sRGB, red: rgb.x, green: rgb.y, blue: rgb.z, opacity: 1)
    }

    /// The colour circle at full saturation, from hue 0 round to 360: the
    /// disc's rim (`GradingDisc`) at the lightness of the scheme.
    static func ring(_ scheme: ColorScheme, steps: Int = 24) -> [Color] {
        GradingDisc.ring(lightness: GradingDisc.lightness(scheme), steps: steps)
    }

    /// A saturation track: the disc from its neutral middle to the rim at `hue`.
    static func saturationTrack(hue: Double, _ scheme: ColorScheme) -> [Color] {
        let lightness = GradingDisc.lightness(scheme)
        return [GradingDisc.colour(hue: hue, saturation: 0, lightness: lightness),
                GradingDisc.colour(hue: hue, saturation: 100, lightness: lightness)]
    }

    /// Mid grey: what no tint makes of the photo's middle grey.
    static var neutral: Color { colour(hue: 0, saturation: 0) }

    /// The point for `hue` (degrees) and `saturation` (0…100) on a disc of `radius` about `center`.
    static func point(hue: Double, saturation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = hue * .pi / 180
        let distance = radius * CGFloat(min(max(saturation, 0), 100) / 100)
        return CGPoint(x: center.x + distance * CGFloat(cos(angle)), y: center.y + distance * CGFloat(sin(angle)))
    }

    /// The hue (0…360) and saturation (0…100) of a point on the disc; the
    /// rim holds past it. Within `centreHold` of the middle the colour is
    /// neutral and `hue` is nil: the hue is left as it was.
    static func colour(at point: CGPoint, center: CGPoint, radius: CGFloat,
                       centreHold: Double = 0.03) -> (hue: Double?, saturation: Double) {
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let distance = (dx * dx + dy * dy).squareRoot() / Double(radius)
        let saturation = min(distance, 1) * 100
        guard distance > centreHold else { return (nil, 0) }
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        return (hue, saturation)
    }
}

/// A colour disc to pick a tint from (adjust-tools §7): the hue around it,
/// neutral grey in the middle, a puck where the zone's tint is.
///
/// - Touching away from the puck puts it there; touching it (within a
///   finger's reach) takes hold of it where it is, so a finger never makes
///   it jump. Dragging past the rim holds the saturation at its largest.
///   One drag is one bracket (`onEditingChanged`) and writes through `write`.
/// - Double-click or double-tap puts the tint back to neutral.
///
/// The sliders under the wheel are its numbers and its keyboard and VoiceOver
/// way in, so the wheel itself is hidden from VoiceOver.
struct GradingWheel: View {
    let hue: Double
    let saturation: Double
    let style: AdjustmentControlStyle
    /// The zone's name, for VoiceOver.
    var label: Text = Text(verbatim: "")
    let write: (_ hue: Double?, _ saturation: Double) -> Void
    let reset: () -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var grab: CGSize?
    @State private var bracket = EditingBracket()
    /// A held arrow key is one step, as on the sliders.
    @State private var keys = ArrowKeyEditing()
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    private var puckSize: CGFloat { style == .touch ? 26 : 18 }

    static func tint(hue: Double, saturation: Double) -> Color { GradingWheelMath.colour(hue: hue, saturation: saturation) }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - puckSize / 2 - 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let puck = GradingWheelMath.point(hue: hue, saturation: saturation, center: center, radius: radius)
            ZStack {
                GradingDiscImage(travel: radius)
                    .overlay { Circle().strokeBorder(contrast == .increased ? Color.hdr.lineStrong : Color.hdr.line) }
                    .frame(width: radius * 2 + puckSize, height: radius * 2 + puckSize)
                    .position(center)
                    .opacity(isEnabled ? 1 : 0.4)
                // The neutral cross, and the tint's reach from the middle to the puck.
                Path { path in
                    path.move(to: CGPoint(x: center.x - radius, y: center.y)); path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - radius)); path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                }
                .stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                if saturation > 0 {
                    Path { path in path.move(to: center); path.addLine(to: puck) }
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                        .shadow(color: .black.opacity(0.25), radius: 0.5)
                }
                // The puck is the colour the photo's middle grey takes: grey with no tint.
                Circle()
                    .fill(Self.tint(hue: hue, saturation: saturation))
                    .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.45), lineWidth: 0.75).padding(-0.75) }
                    .frame(width: puckSize, height: puckSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .position(puck)
                    .scaleEffect(grab == nil ? 1 : 1.12, anchor: .center)
                    .allowsHitTesting(false)
            }
            .contentShape(.circle)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { drag in
                    guard isEnabled, isPrimaryPointerEvent else { return }
                    if grab == nil {
                        bracket.begin(onEditingChanged)
                        let near = hypot(drag.startLocation.x - puck.x, drag.startLocation.y - puck.y) <= puckSize * 1.4
                        grab = near ? CGSize(width: puck.x - drag.startLocation.x, height: puck.y - drag.startLocation.y) : .zero
                    }
                    let offset = grab ?? .zero
                    let colour = GradingWheelMath.colour(
                        at: CGPoint(x: drag.location.x + offset.width, y: drag.location.y + offset.height),
                        center: center, radius: radius)
                    write(colour.hue, colour.saturation)
                }
                .onEnded { _ in finish() })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if isEnabled { reset() } })
            .onChange(of: isEnabled) { if !isEnabled { finish() } }
            .onDisappear { finish() }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if focused { Circle().stroke(Color.hdr.focus, lineWidth: 2).padding(-2) }
        }
        #if os(macOS)
        // With keyboard navigation on: ← → turn the hue, ↑ ↓ change the saturation (⇧ ten at a time).
        .focusable(interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat, .up]) { press in
            let turns = press.key == .leftArrow || press.key == .rightArrow
            keys.perform(ArrowKeyInput(press), verticalOnly: false, notify: onEditingChanged) { steps in
                if turns {
                    write(Self.turned(hue, by: Double(steps)), saturation)
                } else {
                    write(hue, min(max(saturation + Double(steps), 0), 100))
                }
            }
            return .handled
        }
        .onChange(of: focused) { if !focused { keys.finish(onEditingChanged) } }
        #endif
        .accessibilityElement()
        .accessibilityLabel(Text("design.grade.wheel \(label)", bundle: .module))
        .accessibilityValue(Text("design.grade.wheelValue \(String(Int(hue.rounded()))) \(String(Int(saturation.rounded())))",
                                 bundle: .module))
        .accessibilityAdjustableAction { direction in
            write(hue, min(max(saturation + (direction == .increment ? 5 : -5), 0), 100))
        }
        .accessibilityAction(named: Text("design.grade.hueUp", bundle: .module)) { write(Self.turned(hue, by: 10), saturation) }
        .accessibilityAction(named: Text("design.grade.hueDown", bundle: .module)) { write(Self.turned(hue, by: -10), saturation) }
        .accessibilityAction(named: Text("design.grade.neutral", bundle: .module)) { reset() }
    }

    /// A hue turned by `degrees`, kept in 0…360.
    static func turned(_ hue: Double, by degrees: Double) -> Double {
        let turned = (hue + degrees).truncatingRemainder(dividingBy: 360)
        return turned < 0 ? turned + 360 : turned
    }

    private func finish() {
        grab = nil
        bracket.finish(onEditingChanged)
    }
}

/// The colour grading (adjust-tools §7): a wheel, hue, saturation and
/// luminance for each of shadows, midtones, highlights and the whole photo,
/// and under them the blending and the balance. The section wires the
/// declarations to `ColorGradingLayout`, which arranges them.
public struct ColorGradingSection: View {
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

    private func number(_ id: String) -> Double {
        if case .number(let value)? = panel.control(id, in: recipe)?.value { return value }
        return 0
    }

    public var body: some View {
        ColorGradingLayout(style: style, showsTitle: showsTitle,
                           colour: { zone in (number(zone.hueID), number(zone.saturationID), number(zone.luminanceID)) },
                           isChanged: { !(panel.control($0, in: recipe)?.isDefault ?? true) },
                           writeWheel: { zone, hue, saturation in
            var edited = recipe
            if let hue { panel.set(zone.hueID, number: hue, in: &edited) }
            panel.set(zone.saturationID, number: saturation, in: &edited)
            recipe = edited
        }, resetWheel: { zone in
            var edited = recipe
            panel.reset(zone.hueID, in: &edited)
            panel.reset(zone.saturationID, in: &edited)
            recipe = edited
        }, wheelEditing: { zone, editing in
            if let declaration = Adjustments.declaration(zone.saturationID) { onEditingChanged(declaration, editing) }
        }, resetAll: {
            var edited = recipe
            for id in ColorGradingLayout<EmptyView>.ids { panel.reset(id, in: &edited) }
            recipe = edited
        }, slider: { id, title, gradient in
            SectionSlider(recipe: $recipe, id: id, panel: panel, style: style, title: title, gradient: gradient,
                          onEditingChanged: onEditingChanged)
        })
    }
}

struct ColorGradingLayout<Slider: View>: View {
    let style: AdjustmentControlStyle
    let showsTitle: Bool
    let colour: (WheelZone) -> (hue: Double, saturation: Double, luminance: Double)
    let isChanged: (String) -> Bool
    let writeWheel: (WheelZone, Double?, Double) -> Void
    let resetWheel: (WheelZone) -> Void
    let wheelEditing: (WheelZone, Bool) -> Void
    let resetAll: () -> Void
    @ViewBuilder let slider: (_ id: String, _ title: Text?, _ gradient: [Color]?) -> Slider

    @State private var zone = WheelZone.midtones
    @State private var isExpanded: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.sectionLayout) private var layout

    init(style: AdjustmentControlStyle, showsTitle: Bool,
         colour: @escaping (WheelZone) -> (hue: Double, saturation: Double, luminance: Double),
         isChanged: @escaping (String) -> Bool,
         writeWheel: @escaping (WheelZone, Double?, Double) -> Void, resetWheel: @escaping (WheelZone) -> Void,
         wheelEditing: @escaping (WheelZone, Bool) -> Void, resetAll: @escaping () -> Void,
         @ViewBuilder slider: @escaping (_ id: String, _ title: Text?, _ gradient: [Color]?) -> Slider) {
        self.style = style
        self.showsTitle = showsTitle
        self.colour = colour
        self.isChanged = isChanged
        self.writeWheel = writeWheel
        self.resetWheel = resetWheel
        self.wheelEditing = wheelEditing
        self.resetAll = resetAll
        self.slider = slider
        _isExpanded = State(initialValue: style == .touch || !showsTitle || Self.ids.contains(where: isChanged))
    }

    static var ids: [String] {
        WheelZone.allCases.flatMap { [$0.hueID, $0.saturationID, $0.luminanceID] }
            + [WheelZone.blendingID, WheelZone.balanceID]
    }

    private func isChanged(zone: WheelZone) -> Bool {
        [zone.hueID, zone.saturationID, zone.luminanceID].contains(where: isChanged)
    }

    private var anyChanged: Bool { Self.ids.contains(where: isChanged) }

    /// A zone's name, after a dot of the colour it gives the photo when it is changed.
    private func zoneTitle(_ zone: WheelZone) -> Text {
        guard isChanged(zone: zone) else { return zone.title }
        let value = colour(zone)
        let dot = Text(Image(systemName: "circle.fill"))
            .font(.system(size: 6))
            .foregroundStyle(GradingWheelMath.colour(hue: value.hue, saturation: value.saturation))
        return dot + Text(verbatim: "\u{2009}") + zone.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if showsTitle { header }
            if isExpanded || !showsTitle {
                if showsTitle {
                    zoneChoice
                } else if layout == .split {
                    // The page names the section: its reset stands beside the zones.
                    HStack(spacing: Space.s2) {
                        zoneChoice
                        header.fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    // A narrow page: the reset above, so the four zones have the whole width.
                    header
                    zoneChoice
                }
                switch layout {
                case .stacked:
                    wheel
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.s1)
                    sliders
                case .split:
                    // The wheel on the left, its numbers and the blending on the right.
                    HStack(alignment: .top, spacing: Space.s4) {
                        wheel
                            .frame(maxWidth: .infinity)
                        sliders
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var header: some View {
        SubsectionHeader(title: Text("design.grade.title", bundle: .module), style: style, showsTitle: showsTitle,
                         isChanged: anyChanged, summary: SectionSummary.changes(Self.ids.filter(isChanged).count),
                         isExpanded: showsTitle && style == .pointer ? $isExpanded : nil,
                         resetLabel: Text("design.grade.reset", bundle: .module), reset: resetAll) { EmptyView() }
    }

    private var zoneChoice: some View {
        SectionSegments(request: SectionSegmentsRequest(
            title: Text("design.grade.zone", bundle: .module),
            options: WheelZone.allCases.map { option in .init(id: option.rawValue, title: zoneTitle(option)) },
            selection: Binding(get: { zone.rawValue }, set: { zone = WheelZone(rawValue: $0) ?? .midtones })),
                        style: style)
    }

    private var wheel: some View {
        let current = colour(zone)
        return GradingWheel(hue: current.hue, saturation: current.saturation, style: style, label: zone.title,
                            write: { writeWheel(zone, $0, $1) }, reset: { resetWheel(zone) },
                            onEditingChanged: { wheelEditing(zone, $0) })
            .frame(maxWidth: style == .touch ? 220 : 168)
    }

    private var sliders: some View {
        let current = colour(zone)
        let spacing = style == .touch ? Space.s2 : Space.s1
        return VStack(alignment: .leading, spacing: spacing) {
            slider(zone.hueID, MixerAttribute.hue.title, GradingWheelMath.ring(scheme))
            slider(zone.saturationID, MixerAttribute.saturation.title,
                   GradingWheelMath.saturationTrack(hue: current.hue, scheme))
            slider(zone.luminanceID, MixerAttribute.luminance.title, nil)
            Divider().padding(.vertical, Space.s1)
            slider(WheelZone.blendingID, nil, nil)
            slider(WheelZone.balanceID, nil, nil)
        }
    }
}

/// One zone's wheel on the recipe, for a host that lays the grading out
/// itself (the iPhone's grading page): the same wheel, writes and undo
/// steps as the section's.
public struct GradingZoneWheel: View {
    @Binding private var recipe: Recipe
    private let panel: AdjustmentPanel
    private let zone: WheelZone
    private let style: AdjustmentControlStyle
    private let onEditingChanged: (ParameterDeclaration, Bool) -> Void

    public init(recipe: Binding<Recipe>, panel: AdjustmentPanel, zone: WheelZone, style: AdjustmentControlStyle,
                onEditingChanged: @escaping (ParameterDeclaration, Bool) -> Void = { _, _ in }) {
        _recipe = recipe
        self.panel = panel
        self.zone = zone
        self.style = style
        self.onEditingChanged = onEditingChanged
    }

    private func number(_ id: String) -> Double {
        if case .number(let value)? = panel.control(id, in: recipe)?.value { return value }
        return 0
    }

    public var body: some View {
        GradingWheel(hue: number(zone.hueID), saturation: number(zone.saturationID), style: style, label: zone.title,
                     write: { hue, saturation in
            var edited = recipe
            if let hue { panel.set(zone.hueID, number: hue, in: &edited) }
            panel.set(zone.saturationID, number: saturation, in: &edited)
            recipe = edited
        }, reset: {
            var edited = recipe
            panel.reset(zone.hueID, in: &edited)
            panel.reset(zone.saturationID, in: &edited)
            recipe = edited
        }, onEditingChanged: { editing in
            if let declaration = Adjustments.declaration(zone.saturationID) { onEditingChanged(declaration, editing) }
        })
    }

    /// The colour a zone gives the photo, for a host's readout or mark.
    public static func colour(hue: Double, saturation: Double) -> Color {
        GradingWheelMath.colour(hue: hue, saturation: saturation)
    }
}

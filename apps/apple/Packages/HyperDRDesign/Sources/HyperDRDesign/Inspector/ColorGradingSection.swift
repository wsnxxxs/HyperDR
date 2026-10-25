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

    static let blendingID = "grade.blending"
    static let balanceID = "grade.balance"
}

/// The wheel's geometry, apart from any view: where a hue and a saturation
/// sit on the disc, and which they are for a point on it. Hue runs clockwise
/// from the right (the angular gradient's own start), saturation from the
/// centre (0) to the rim (100).
enum GradingWheelMath {
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
    let write: (_ hue: Double?, _ saturation: Double) -> Void
    let reset: () -> Void
    let onEditingChanged: (Bool) -> Void

    @State private var grab: CGSize?
    @State private var bracket = EditingBracket()
    @Environment(\.isEnabled) private var isEnabled

    private var puckSize: CGFloat { style == .touch ? 26 : 18 }

    static func tint(hue: Double, saturation: Double) -> Color {
        Color(hue: hue / 360, saturation: saturation / 100, brightness: 0.95)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let radius = side / 2 - puckSize / 2 - 2
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let puck = GradingWheelMath.point(hue: hue, saturation: saturation, center: center, radius: radius)
            ZStack {
                Circle()
                    .fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.9) },
                                          center: .center))
                    .overlay {
                        Circle().fill(RadialGradient(colors: [Color.hdr.histogramBackdrop, Color.hdr.histogramBackdrop.opacity(0)],
                                                     center: .center, startRadius: 0, endRadius: radius))
                    }
                    .overlay { Circle().strokeBorder(Color.hdr.line) }
                    .frame(width: radius * 2 + puckSize, height: radius * 2 + puckSize)
                    .position(center)
                    .opacity(isEnabled ? 1 : 0.4)
                // The neutral cross.
                Path { path in
                    path.move(to: CGPoint(x: center.x - radius, y: center.y)); path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - radius)); path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                }
                .stroke(Color.hdr.lineStrong.opacity(0.5), lineWidth: 0.5)
                Circle()
                    .fill(saturation > 0 ? Self.tint(hue: hue, saturation: saturation) : Color.hdr.surfaceCard)
                    .overlay { Circle().strokeBorder(Color.white, lineWidth: 2) }
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5).padding(-1) }
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
        .accessibilityHidden(true)
    }

    private func finish() {
        grab = nil
        bracket.finish(onEditingChanged)
    }
}

/// The four zones as small discs to choose from, each with a dot where its
/// tint is; a mark shows a zone with changes.
private struct GradingZoneTab: View {
    let zone: WheelZone
    let hue: Double
    let saturation: Double
    let isChanged: Bool
    let isSelected: Bool
    let style: AdjustmentControlStyle
    let choose: () -> Void

    var body: some View {
        let side: CGFloat = style == .touch ? 52 : 40
        Button(action: choose) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.7, brightness: 0.8) },
                                              center: .center))
                        .overlay { Circle().fill(RadialGradient(colors: [Color.hdr.histogramBackdrop, Color.hdr.histogramBackdrop.opacity(0)],
                                                                 center: .center, startRadius: 0, endRadius: side / 2)) }
                        .opacity(isSelected ? 1 : 0.55)
                    Circle()
                        .fill(saturation > 0 ? GradingWheel.tint(hue: hue, saturation: saturation) : Color.hdr.surfaceCard)
                        .overlay { Circle().strokeBorder(Color.white, lineWidth: 1.5) }
                        .frame(width: 9, height: 9)
                        .offset(x: CGFloat(cos(hue * .pi / 180) * saturation / 100) * (side / 2 - 6),
                                y: CGFloat(sin(hue * .pi / 180) * saturation / 100) * (side / 2 - 6))
                }
                .frame(width: side, height: side)
                .overlay { Circle().strokeBorder(isSelected ? Color.hdr.accent : Color.hdr.line, lineWidth: isSelected ? 2 : 1).padding(-2) }
                HStack(spacing: 3) {
                    zone.title
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.hdr.inkStrong : Color.hdr.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if isChanged { Circle().fill(Color.hdr.accent).frame(width: 4, height: 4) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: style == .touch ? 44 : 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(zone.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if showsTitle { header }
            if isExpanded || !showsTitle {
                HStack(spacing: 0) {
                    ForEach(WheelZone.allCases) { option in
                        let value = colour(option)
                        GradingZoneTab(zone: option, hue: value.hue, saturation: value.saturation,
                                       isChanged: isChanged(zone: option), isSelected: zone == option, style: style) {
                            zone = option
                        }
                    }
                }
                let current = colour(zone)
                GradingWheel(hue: current.hue, saturation: current.saturation, style: style,
                             write: { writeWheel(zone, $0, $1) }, reset: { resetWheel(zone) },
                             onEditingChanged: { wheelEditing(zone, $0) })
                    .frame(maxWidth: style == .touch ? 260 : 200)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s1)
                VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s3) {
                    slider(zone.hueID, MixerAttribute.hue.title, TrackGradient.ring())
                    slider(zone.saturationID, MixerAttribute.saturation.title,
                           TrackGradient.saturation(toward: GradingWheel.tint(hue: current.hue, saturation: 100)))
                    slider(zone.luminanceID, MixerAttribute.luminance.title, nil)
                }
                Divider().padding(.vertical, Space.s1)
                VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s3) {
                    slider(WheelZone.blendingID, nil, nil)
                    slider(WheelZone.balanceID, nil, nil)
                }
                if !showsTitle, anyChanged { resetButton }
            }
        }
    }

    private var resetButton: some View {
        Button(action: resetAll) {
            Text("design.grade.reset", bundle: .module)
                .font(.system(size: TypeScale.Size.caption, weight: .medium))
                .foregroundStyle(Color.hdr.accent)
                .frame(minHeight: style == .touch ? 44 : 22)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

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
                    Text("design.grade.title", bundle: .module)
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
            if anyChanged { resetButton }
        }
    }
}

import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The crop pane's controls on the dock, laid out as the other panes: the
/// pane's buttons above (a quarter turn left, mirror, the ratio with its
/// orientation, reset), the dial's readout, a ring for each dial (rotation,
/// vertical, horizontal) and the ruler under them.
/// The crop box itself is on the canvas (`CropOverlay`).
///
/// Every button is one undo step; a dial's drag is one, as the box's is.
struct CropControls: View {
    @Binding var recipe: Recipe
    /// The photo's own size; nil before a photo.
    let photo: GeometrySize?
    var axis: Axis = .horizontal
    var large = false
    let onEditing: (Bool) -> Void

    @State private var dial = CropDial.straighten

    private var geometry: Geometry { recipe.geometry }

    var body: some View {
        VStack(spacing: large ? Space.s3 : Space.s2) {
            buttons.padding(.horizontal, Space.s4)
            readout
            rings
            AdjustmentRuler(control: dial.ruler(geometry), write: { set(dial, $0) }, reset: { set(dial, 0) },
                            onEditingChanged: onEditing)
                .id(dial)
                .frame(height: large ? 52 : 40)
        }
        .disabled(photo == nil)
    }

    private func set(_ dial: CropDial, _ value: Double) {
        var edited = geometry
        dial.set(value, in: &edited)
        recipe.geometry = edited
    }

    // MARK: Buttons

    private var buttons: some View {
        HStack(spacing: Space.s2) {
            button("rotate.left", Text("ios.crop.rotate")) { recipe.geometry = geometry.turnedLeft() }
            button("arrow.left.and.right.righttriangle.left.righttriangle.right", Text("ios.crop.flip")) {
                recipe.geometry = geometry.mirrored()
            }
            Spacer(minLength: Space.s1)
            aspectMenu
            button("arrow.counterclockwise", Text("ios.crop.reset")) { recipe.geometry = .identity }
                .disabled(geometry.isIdentity)
        }
        .frame(maxWidth: 420)
    }

    private func button(_ symbol: String, _ label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// The ratios, in the photo's orientation: 4:5 on a landscape photo is 5:4.
    private var aspectMenu: some View {
        let shown = geometry.aspect.isLandscape ? geometry.aspect.turned : geometry.aspect
        return Menu {
            Picker(selection: Binding(get: { shown }, set: { preset in
                let frame = photo.map(geometry.frameSize(of:))
                let landscape = frame.map { $0.width > $0.height } ?? false
                choose(landscape ? preset.turned : preset)
            })) {
                ForEach(CropAspect.presets, id: \.self) { preset in
                    Self.name(preset).tag(preset)
                }
            } label: {
                Text("ios.crop.aspect")
            }
            // A fixed ratio either way up; the photo's own, free and square have one.
            if geometry.aspect.turned != geometry.aspect {
                Section {
                    Picker(selection: Binding(get: { geometry.aspect.isLandscape },
                                              set: { if $0 != geometry.aspect.isLandscape { choose(geometry.aspect.turned) } })) {
                        Label { Text("ios.crop.portrait") } icon: { Image(systemName: "rectangle.portrait") }.tag(false)
                        Label { Text("ios.crop.landscape") } icon: { Image(systemName: "rectangle") }.tag(true)
                    } label: {
                        Text("ios.crop.aspect")
                    }
                }
            }
        } label: {
            HStack(spacing: Space.s1) {
                Image(systemName: "aspectratio")
                // Named for what it opens; the ratio in force is checked in the menu.
                Text("ios.crop.aspect")
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 36)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel(Text("ios.crop.aspect"))
    }

    private func choose(_ aspect: CropAspect) {
        guard let photo else { return }
        recipe.geometry = geometry.settingAspect(aspect, photo: photo)
    }

    static func name(_ aspect: CropAspect) -> Text {
        switch aspect {
        case .original: Text("ios.crop.aspect.original")
        case .free: Text("ios.crop.aspect.free")
        case .square: Text("ios.crop.aspect.square")
        default: Text(verbatim: aspect.rawValue)
        }
    }

    // MARK: Dials

    private var readout: some View {
        HStack(spacing: Space.s2) {
            dial.label.font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            Text(verbatim: dial.readout(geometry))
                .font(.footnote.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
        }
        .frame(minHeight: 28)
    }

    private var rings: some View {
        HStack(spacing: Space.s2) {
            ForEach(CropDial.allCases, id: \.self) { item in
                CropRing(dial: item, value: item.value(geometry), isCurrent: item == dial)
                    .onTapGesture { withAnimation(.smooth(duration: 0.2)) { dial = item } }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { set(item, 0) })
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The crop pane's dials.
enum CropDial: CaseIterable, Hashable {
    case straighten, vertical, horizontal

    var label: Text {
        switch self {
        case .straighten: Text("ios.crop.straighten")
        case .vertical: Text("ios.crop.vertical")
        case .horizontal: Text("ios.crop.horizontal")
        }
    }

    var symbol: String {
        switch self {
        case .straighten: "level"
        case .vertical: "trapezoid.and.line.vertical"
        case .horizontal: "trapezoid.and.line.horizontal"
        }
    }

    var range: ClosedRange<Double> {
        self == .straighten ? Geometry.angleRange : Geometry.perspectiveRange
    }

    func value(_ geometry: Geometry) -> Double {
        switch self {
        case .straighten: geometry.angle
        case .vertical: geometry.vertical
        case .horizontal: geometry.horizontal
        }
    }

    func set(_ value: Double, in geometry: inout Geometry) {
        let value = min(max(value, range.lowerBound), range.upperBound)
        switch self {
        case .straighten: geometry.angle = value
        case .vertical: geometry.vertical = value
        case .horizontal: geometry.horizontal = value
        }
    }

    /// "+2.5°" for the straightening, "−12" for the perspective, "0" at rest.
    func readout(_ geometry: Geometry) -> String {
        let value = value(geometry)
        if value == 0 { return self == .straighten ? "0°" : "0" }
        let text = self == .straighten ? String(format: "%+.1f°", value) : String(format: "%+.0f", value)
        return text.replacingOccurrences(of: "-", with: "−")
    }

    /// The ruler: a tick a degree for the straightening (major every 5°), and
    /// the percent controls' scale for the perspective.
    func ruler(_ geometry: Geometry) -> RulerControl {
        let value = value(geometry)
        let range = range
        let straighten = self == .straighten
        return RulerControl(value: value, number: value, tint: Color.hdr.accent, label: label,
                            readout: readout(geometry), step: straighten ? 0.1 : 1, origin: 0) { width in
            let reach = Double(max(width * RulerScale.reachFraction, RulerScale.minimumReach))
            return RulerScale(range: range, step: straighten ? 0.1 : 1, defaultValue: 0,
                              majorTick: straighten ? 5 : 10, pointsPerUnit: straighten ? 8 : reach / 100)
        }
    }
}

/// A dial's ring, drawn as the adjustment rings: empty at zero, filling
/// clockwise for positive values and anticlockwise for negative ones.
private struct CropRing: View {
    let dial: CropDial
    let value: Double
    let isCurrent: Bool

    var body: some View {
        let deviation = value / dial.range.upperBound
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(isCurrent ? 0.28 : 0.14), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: abs(deviation))
                    .stroke(Color.hdr.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: deviation < 0 ? -1 : 1)
                    .animation(.smooth(duration: 0.15), value: deviation)
                Image(systemName: dial.symbol)
                    .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
            }
            .frame(width: 44, height: 44)
            .background(Circle().fill(isCurrent ? Color.white.opacity(0.12) : .clear))
            dial.label
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 62)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dial.label)
        .accessibilityValue(Text(verbatim: "\(value)"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}

import HyperDRRecipe
import SwiftUI

/// The crop pane as an inspector column (the Mac's inspector and the iPad's
/// sidebar), beside `AdjustmentInspector`; the crop box itself is drawn over
/// the canvas by the host.
///
/// - Above: a quarter turn left, mirroring and reset, each one undo step;
///   under them Auto (`GeometryUpright`), whose menu holds the other modes,
///   with a line when it could not straighten the photo.
/// - Ratio: the photo's own, free, square and the fixed ratios as tiles drawn
///   in their shape, in the photo's orientation, and a switch for the other
///   way up when the ratio has one.
/// - Rotate and perspective: sliders, each drag one step (`onEditingChanged`).
public struct GeometryInspector: View {
    @Binding private var geometry: Geometry
    /// The photo's own size; nil before a photo.
    private let photo: GeometrySize?
    private let style: AdjustmentControlStyle
    private let upright: GeometryUpright?
    private let onEditingChanged: (Bool) -> Void

    @State private var expanded: Set<Section> = [.aspect, .transform]

    enum Section: Hashable { case aspect, transform }

    public init(geometry: Binding<Geometry>, photo: GeometrySize?, style: AdjustmentControlStyle = .pointer,
                upright: GeometryUpright? = nil, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _geometry = geometry
        self.photo = photo
        self.style = style
        self.upright = upright
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actions
                .padding(.horizontal, 20)
                .padding(.vertical, style == .touch ? Space.s3 : Space.s2)
            group(.aspect, title: Text("crop.aspect", bundle: .module), symbol: "aspectratio") { aspects }
            group(.transform, title: Text("crop.transform", bundle: .module), symbol: "perspective") { dials }
        }
        .disabled(photo == nil)
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) { tiles }
            if let upright { auto(upright) }
        }
    }

    @ViewBuilder private var tiles: some View {
            action("rotate.left", Text("crop.rotate90", bundle: .module)) { geometry = geometry.turnedLeft() }
            action("arrow.left.and.right.righttriangle.left.righttriangle.right", Text("crop.flip", bundle: .module)) {
                geometry = geometry.mirrored()
            }
            action("arrow.counterclockwise", Text("crop.reset", bundle: .module)) { geometry = .identity }
                .disabled(geometry.isIdentity)
    }

    /// Auto as a button with a menu; while it analyses, a spinner in its place.
    @ViewBuilder private func auto(_ upright: GeometryUpright) -> some View {
        let title = GeometryUpright.name(.auto)
        Group {
            if upright.analyzing != nil {
                Button {} label: {
                    HStack(spacing: Space.s2) {
                        ProgressView().controlSize(.small)
                        title
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(true)
            } else {
                Menu {
                    upright.menuItems
                } label: {
                    Label { title } icon: { Image(systemName: GeometryUpright.symbol) }
                        .frame(maxWidth: .infinity)
                } primaryAction: {
                    upright.run(.auto)
                }
                .menuStyle(.button)
            }
        }
        .controlSize(style == .touch ? .extraLarge : .large)
        .help(title)
        if let notice = upright.notice, upright.analyzing == nil {
            Label { GeometryUpright.text(notice) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.system(size: 11))
                .foregroundStyle(Color.hdr.inkMuted)
        }
    }

    private func action(_ symbol: String, _ title: Text, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: Space.s1) {
                Image(systemName: symbol).font(.system(size: style == .touch ? 17 : 15))
                title.font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: style == .touch ? 58 : 48)
            .background(RoundedRectangle(cornerRadius: Radius.lg).fill(Color.hdr.surfaceCard))
            .contentShape(.rect)
        }
        .buttonStyle(GeometryTileStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Ratio

    /// Fixed ratios are shown the way up the crop is (or the photo, before one).
    private var landscape: Bool {
        if geometry.aspect.turned != geometry.aspect { return geometry.aspect.isLandscape }
        guard let photo else { return false }
        let frame = geometry.frameSize(of: photo)
        return frame.width > frame.height
    }

    private var aspects: some View {
        let columns = [GridItem(.adaptive(minimum: style == .touch ? 64 : 56), spacing: Space.s2)]
        return VStack(alignment: .leading, spacing: Space.s3) {
            LazyVGrid(columns: columns, spacing: Space.s2) {
                ForEach(CropAspect.presets, id: \.self) { preset in
                    let aspect = landscape ? preset.turned : preset
                    AspectTile(name: Self.name(aspect), ratio: shapeRatio(aspect), isSelected: geometry.aspect == aspect,
                               height: style == .touch ? 60 : 52) { choose(aspect) }
                }
            }
            if geometry.aspect.turned != geometry.aspect {
                ParameterSegmented(Text("crop.orientation", bundle: .module),
                                   selection: Binding(get: { geometry.aspect.isLandscape },
                                                      set: { if $0 != geometry.aspect.isLandscape { choose(geometry.aspect.turned) } }),
                                   choices: [SegmentedChoice(Text("crop.portrait", bundle: .module), value: false,
                                                             systemImage: "rectangle.portrait"),
                                             SegmentedChoice(Text("crop.landscape", bundle: .module), value: true,
                                                             systemImage: "rectangle")])
                    .frame(minHeight: style == .touch ? 44 : nil)
            }
        }
    }

    /// The shape a tile draws: free is drawn as the crop it holds.
    private func shapeRatio(_ aspect: CropAspect) -> Double {
        guard let photo else { return aspect == .free ? 1 : aspect.ratio(frame: GeometrySize(width: 3, height: 2)) ?? 1 }
        let frame = geometry.frameSize(of: photo)
        if aspect == .free {
            let crop = geometry.cropRect(for: photo)
            return crop.width / max(crop.height, 1)
        }
        return aspect.ratio(frame: frame) ?? 1
    }

    private func choose(_ aspect: CropAspect) {
        guard let photo else { return }
        geometry = geometry.settingAspect(aspect, photo: photo)
    }

    public static func name(_ aspect: CropAspect) -> Text {
        switch aspect {
        case .original: Text("crop.aspect.original", bundle: .module)
        case .free: Text("crop.aspect.free", bundle: .module)
        case .square: Text(verbatim: "1:1")
        default: Text(verbatim: aspect.rawValue)
        }
    }

    // MARK: Rotation and perspective

    private var dials: some View {
        VStack(alignment: .leading, spacing: style == .touch ? Space.s2 : Space.s4) {
            slider(Text("crop.rotate", bundle: .module), value: \.angle,
                   spec: .signed(Geometry.angleRange, step: 0.1, format: Self.degrees))
            slider(Text("crop.vertical", bundle: .module), value: \.vertical,
                   spec: .signed(Geometry.perspectiveRange, step: 1, format: .signed(fractionDigits: 0)))
            slider(Text("crop.horizontal", bundle: .module), value: \.horizontal,
                   spec: .signed(Geometry.perspectiveRange, step: 1, format: .signed(fractionDigits: 0)))
        }
    }

    /// "+2.5°", "0°": the degree sign follows the number.
    private static let degrees = ParameterFormat { value in
        abs(value) < 0.05 ? "0°" : ParameterFormat.signed(fractionDigits: 1).display(value) + "°"
    }

    @ViewBuilder
    private func slider(_ title: Text, value path: WritableKeyPath<Geometry, Double>, spec: ParameterSpec) -> some View {
        let value = Binding(get: { geometry[keyPath: path] }, set: { new in
            var edited = geometry
            edited[keyPath: path] = min(max(new, spec.range.lowerBound), spec.range.upperBound)
            geometry = edited
        })
        switch style {
        case .pointer:
            ParameterSlider(title, value: value, spec: spec, onEditingChanged: onEditingChanged,
                            onReset: { value.wrappedValue = 0 })
        case .touch:
            TouchParameterSlider(title, value: value, spec: spec, onEditingChanged: onEditingChanged)
        }
    }

    // MARK: Groups

    private func group(_ section: Section, title: Text, symbol: String,
                       @ViewBuilder content: () -> some View) -> some View {
        ParameterGroup(title, systemImage: symbol,
                       isExpanded: Binding(get: { expanded.contains(section) },
                                           set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } }),
                       collapsible: style == .pointer) {
            content()
        } accessory: {
            EmptyView()
        }
    }
}

/// A ratio as a tile: its shape drawn to scale over its name.
private struct AspectTile: View {
    let name: Text
    /// Width over height.
    let ratio: Double
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                let side: CGFloat = 20
                let size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isSelected ? Color.hdr.accent : Color.hdr.inkMuted, lineWidth: 1.5)
                    .frame(width: max(6, size.width), height: max(6, size.height))
                    .frame(width: side, height: side)
                name
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Color.hdr.inkStrong : Color.hdr.ink)
            .frame(maxWidth: .infinity, minHeight: height)
            .background {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(isSelected ? Color.hdr.accentSoft : Color.hdr.surfaceCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(isSelected ? Color.hdr.accent : .clear, lineWidth: 1)
                    }
            }
            .contentShape(.rect)
        }
        .buttonStyle(GeometryTileStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

/// Dims a tile while pressed and when disabled.
private struct GeometryTileStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The Crop tool (ipad-studio §3.4): a quarter turn left, mirroring, Auto
/// (its other modes on a long press) and reset as large buttons, with a line
/// when Auto changed nothing; the ratios as tiles drawn in their shape, in
/// the way up of the crop (or the photo, before one), with the other way up a
/// switch away; and rotation and perspective as Studio sliders. The crop box
/// itself is on the canvas (`CropOverlay`). Every button is one undo step, and
/// so is each slider's drag.
struct PadCropTool: View {
    @Binding var geometry: Geometry
    /// The photo's own size; nil before a photo.
    let photo: GeometrySize?
    var columns = 1
    var upright: GeometryUpright?
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: PadMetrics.rowSpacing) {
                PadActionTile(title: Text("ios.crop.rotate"), symbol: "rotate.left") { geometry = geometry.turnedLeft() }
                PadActionTile(title: Text("ios.crop.flip"),
                              symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    geometry = geometry.mirrored()
                }
                if let upright { PadUprightTile(upright: upright) }
                PadActionTile(title: Text("ios.crop.reset"), symbol: "arrow.counterclockwise") { geometry = .identity }
                    .disabled(geometry.isIdentity)
            }
            if let notice = upright?.notice {
                Label { GeometryUpright.text(notice) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PadSection(Text("ios.crop.aspect")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: PadMetrics.rowSpacing)],
                          spacing: PadMetrics.rowSpacing) {
                    ForEach(CropAspect.presets, id: \.self) { preset in
                        let aspect = landscape ? preset.turned : preset
                        AspectTile(name: CropControls.name(aspect), ratio: shapeRatio(aspect),
                                   isSelected: geometry.aspect == aspect) { choose(aspect) }
                    }
                }
                if geometry.aspect.turned != geometry.aspect {
                    PadSegments(options: [
                        .init(value: false, label: Text("ios.crop.portrait"), symbol: "rectangle.portrait"),
                        .init(value: true, label: Text("ios.crop.landscape"), symbol: "rectangle"),
                    ], selection: geometry.aspect.isLandscape) { isLandscape in
                        if isLandscape != geometry.aspect.isLandscape { choose(geometry.aspect.turned) }
                    }
                }
            }
            PadRows(columns: columns) {
                ForEach(CropDial.allCases, id: \.self) { dial in
                    PadSlider(dial.label, value: binding(dial), spec: Self.spec(dial),
                              onEditingChanged: onEditingChanged)
                }
            }
        }
        .disabled(photo == nil)
        .sensoryFeedback(.selection, trigger: geometry.aspect)
    }

    /// Fixed ratios are shown the way up the crop is (or the photo, before one).
    private var landscape: Bool {
        if geometry.aspect.turned != geometry.aspect { return geometry.aspect.isLandscape }
        guard let photo else { return false }
        let frame = geometry.frameSize(of: photo)
        return frame.width > frame.height
    }

    /// The shape a tile draws: free is drawn as the crop it holds.
    private func shapeRatio(_ aspect: CropAspect) -> Double {
        guard let photo else { return aspect.ratio(frame: GeometrySize(width: 3, height: 2)) ?? 1 }
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

    private func binding(_ dial: CropDial) -> Binding<Double> {
        Binding(get: { dial.value(geometry) }, set: { value in
            var edited = geometry
            dial.set(value, in: &edited)
            geometry = edited
        })
    }

    /// The dial's slider: a degree a tick for the straightening, whole steps
    /// for the perspective, both filled from zero.
    static func spec(_ dial: CropDial) -> ParameterSpec {
        let degrees = dial == .straighten
        return .signed(dial.range, step: degrees ? 0.1 : 1, format: ParameterFormat { PadCropReadout.text($0, degrees: degrees) })
    }
}

/// "+2.5°" for the straightening, "−12" for the perspective, "0" at rest, as
/// the iPhone's crop dials read.
nonisolated enum PadCropReadout {
    static func text(_ value: Double, degrees: Bool) -> String {
        if abs(value) < (degrees ? 0.05 : 0.5) { return degrees ? "0°" : "0" }
        let text = degrees ? String(format: "%+.1f°", value) : String(format: "%+.0f", value)
        return text.replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

/// Auto as a `PadActionTile`: a tap runs it, a long press offers the other
/// modes; a spinner while it runs.
private struct PadUprightTile: View {
    let upright: GeometryUpright
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let running = upright.analyzing != nil
        Menu {
            upright.menuItems
        } label: {
            VStack(spacing: 4) {
                if running {
                    ProgressView().frame(height: 20)
                } else {
                    Image(systemName: GeometryUpright.symbol).font(.system(size: 17, weight: .medium))
                }
                GeometryUpright.name(.auto).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padRow()
            .contentShape(.rect)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: PadMetrics.rowRadius))
            .hoverEffect(.highlight)
        } primaryAction: {
            upright.run(.auto)
        }
        .buttonStyle(.plain)
        .disabled(running)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(GeometryUpright.name(.auto))
    }
}

/// A ratio as a tile: its shape drawn to scale over its name.
private struct AspectTile: View {
    let name: Text
    /// Width over height.
    let ratio: Double
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                let side: CGFloat = 20
                let size = ratio >= 1 ? CGSize(width: side, height: side / ratio) : CGSize(width: side * ratio, height: side)
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(isSelected ? Color.hdr.accent : Color.secondary, lineWidth: 1.5)
                    .frame(width: max(6, size.width), height: max(6, size.height))
                    .frame(width: side, height: side)
                name
                    .font(.caption.weight(isSelected ? .semibold : .regular).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background {
                RoundedRectangle(cornerRadius: PadMetrics.rowRadius, style: .continuous)
                    .fill(isSelected ? Color.hdr.accent.opacity(0.16) : Color.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: PadMetrics.rowRadius, style: .continuous)
                            .strokeBorder(isSelected ? Color.hdr.accent : .clear, lineWidth: 1.5)
                    }
            }
            .contentShape(.rect)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: PadMetrics.rowRadius))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .animation(.smooth(duration: 0.15), value: isSelected)
    }
}

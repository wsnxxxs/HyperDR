import HyperDRDesign
import HyperDRRecipe
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Over the canvas in the crop pane: the crop box with its corners, and
/// thirds while it is dragged. The canvas dims the photo outside it
/// (`GeometryDisplay.dimsOutsideCrop`), in linear light, so HDR highlights
/// dim too.
///
/// - A corner or an edge resizes the box; inside it the box moves. A fixed
///   ratio holds while resizing (Free lets each edge go its own way).
/// - The box never leaves the photo: a drag stops where the photo ends.
/// - While a drag is under way the photo stays where it is (`freeze`); when
///   it ends, the canvas fits the new crop.
struct CropOverlay: View {
    let layout: CropLayout
    /// Thirds over the crop while anything in the pane is dragged.
    let adjusting: Bool
    @Binding var freeze: CropLayout?
    let write: (Geometry) -> Void
    let onEditing: (Bool) -> Void

    @State private var drag: (kind: CropDrag, start: GeometryRect, geometry: Geometry)?

    var body: some View {
        let box = layout.cropRect
        ZStack {
            if drag != nil || adjusting { thirds(box) }
            Rectangle()
                .path(in: box)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
            corners(box)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }
        .contentShape(.rect)
        .gesture(gesture(box))
        #if os(macOS)
        // The pointer says what a press would take hold of.
        .onContinuousHover { phase in
            guard drag == nil else { return }
            switch phase {
            case .active(let point): Self.cursor(CropDrag.at(point, box: box)).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        #endif
        .allowsHitTesting(true)
        .accessibilityHidden(true)
    }

    #if os(macOS)
    static func cursor(_ kind: CropDrag?) -> NSCursor {
        switch kind {
        case .move: return .openHand
        case .resize(let x, let y):
            let position: NSCursor.FrameResizePosition = switch (x, y) {
            case (-1, -1): .topLeft
            case (1, -1): .topRight
            case (-1, 1): .bottomLeft
            case (1, 1): .bottomRight
            case (-1, _): .left
            case (1, _): .right
            case (_, -1): .top
            default: .bottom
            }
            return .frameResize(position: position, directions: .all)
        case nil: return .arrow
        }
    }
    #endif

    private func thirds(_ box: CGRect) -> some View {
        Path { path in
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3, y = box.minY + box.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
        .transition(.opacity)
    }

    /// An L at each corner, just inside the box.
    private func corners(_ box: CGRect) -> Path {
        let length = min(20, box.width / 3, box.height / 3), inset: CGFloat = 1.5
        return Path { path in
            for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                   (box.maxX, box.maxY, -1.0, -1.0), (box.minX, box.maxY, 1.0, -1.0)] {
                let corner = CGPoint(x: x + inset * dx, y: y + inset * dy)
                path.move(to: CGPoint(x: corner.x + length * dx, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + length * dy))
            }
        }
    }

    private func gesture(_ box: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    guard let kind = CropDrag.at(value.startLocation, box: box) else { return }
                    drag = (kind, layout.geometry.cropRect(for: layout.photo), layout.geometry)
                    freeze = layout
                    onEditing(true)
                }
                guard let drag else { return }
                let scale = layout.scale
                let delta = GeometryPoint(x: Double(value.translation.width) / scale,
                                          y: Double(value.translation.height) / scale)
                let frame = drag.geometry.frameSize(of: layout.photo)
                let ratio = drag.geometry.aspect == .free ? nil
                    : drag.geometry.aspect.ratio(frame: frame) ?? drag.start.width / drag.start.height
                let rect = drag.kind.apply(delta, to: drag.start, ratio: ratio, quad: drag.geometry.quad(for: layout.photo),
                                           minimum: max(frame.width, frame.height) * 0.06)
                var geometry = drag.geometry
                geometry.crop = CropRect(centre: rect.centre, size: rect.size, frame: frame)
                write(geometry)
            }
            .onEnded { _ in
                guard drag != nil else { return }
                drag = nil
                onEditing(false)
                freeze = nil
            }
    }
}

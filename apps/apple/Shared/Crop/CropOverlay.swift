import HyperDRDesign
import HyperDRRecipe
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Over the canvas in the crop pane: the crop box with its corners and the
/// middles of its edges, and thirds while it is dragged. The canvas dims the
/// photo outside it (`GeometryDisplay.dimsOutsideCrop`), in linear light, so
/// HDR highlights dim too.
///
/// - A corner or an edge resizes the box; inside it the box moves. A fixed
///   ratio holds while resizing (Free lets each edge go its own way). A finger
///   takes hold of an edge within `CropDrag.reach` of it.
/// - The box never leaves the photo: a drag stops where the photo ends, with a
///   tap of the haptics (iOS) or the trackpad (Mac) when it does.
/// - While a drag is under way the photo stays where it is (`freeze`); when
///   it ends, the canvas glides to fit the new crop (at once with Reduce Motion).
/// - A double tap inside the box gives the largest crop of its ratio again,
///   keeping the rotation and perspective; one undo step.
struct CropOverlay: View {
    let layout: CropLayout
    /// Thirds over the crop while anything in the pane is dragged.
    let adjusting: Bool
    @Binding var freeze: CropLayout?
    let write: (Geometry) -> Void
    let onEditing: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: (kind: CropDrag, start: GeometryRect, geometry: Geometry)?
    /// True while the drag gesture is alive; it falls back on its own when the
    /// system cancels the gesture, which never calls `onEnded`.
    @GestureState private var pressing = false
    /// The glide to the fitted crop after a drag.
    @State private var settling: Task<Void, Never>?
    /// The drag is held at the photo's edge.
    @State private var stopped = false
    /// Counters for the haptics.
    @State private var stops = 0
    @State private var resets = 0

    /// How long the canvas takes to fit the crop after a drag.
    static let settleDuration = 0.3

    var body: some View {
        let box = layout.cropRect
        let showsThirds = drag != nil || adjusting
        ZStack {
            thirds(box)
                .opacity(showsThirds ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: showsThirds)
            Rectangle()
                .path(in: box)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
            handles(box)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }
        .contentShape(.rect)
        .gesture(gesture(box))
        // A cancelled drag (a system gesture, the view rebuilt) ends as a finished one.
        .onChange(of: pressing) { _, now in if !now { endDrag(with: nil) } }
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            if box.contains(tap.location) { resetCrop() }
        })
        #if os(iOS)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.6), trigger: stops)
        .sensoryFeedback(.impact(weight: .light), trigger: resets)
        #else
        .sensoryFeedback(.alignment, trigger: stops)
        #endif
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
        // Leaving the pane mid-drag or mid-glide leaves nothing held.
        .onDisappear {
            settling?.cancel()
            settling = nil
            if drag != nil {
                drag = nil
                stopped = false
                finishEditing()
            }
            freeze = nil
        }
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
    }

    /// An L at each corner and a bar at the middle of each edge, just inside the box.
    private func handles(_ box: CGRect) -> Path {
        let length = min(20, box.width / 3, box.height / 3), inset: CGFloat = 1.5
        return Path { path in
            for (x, y, dx, dy) in [(box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1.0, 1.0),
                                   (box.maxX, box.maxY, -1.0, -1.0), (box.minX, box.maxY, 1.0, -1.0)] {
                let corner = CGPoint(x: x + inset * dx, y: y + inset * dy)
                path.move(to: CGPoint(x: corner.x + length * dx, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + length * dy))
            }
            // The edges' bars only where they stand clear of the corners.
            let bar = min(18, box.width / 5), column = min(18, box.height / 5)
            if box.width > 3 * length + bar {
                for y in [box.minY + inset, box.maxY - inset] {
                    path.move(to: CGPoint(x: box.midX - bar / 2, y: y))
                    path.addLine(to: CGPoint(x: box.midX + bar / 2, y: y))
                }
            }
            if box.height > 3 * length + column {
                for x in [box.minX + inset, box.maxX - inset] {
                    path.move(to: CGPoint(x: x, y: box.midY - column / 2))
                    path.addLine(to: CGPoint(x: x, y: box.midY + column / 2))
                }
            }
        }
    }

    private func gesture(_ box: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($pressing) { _, pressing, _ in pressing = true }
            .onChanged { value in
                if drag == nil {
                    guard let kind = CropDrag.at(value.startLocation, box: box) else { return }
                    // Taking hold mid-glide keeps the photo where it is now.
                    settling?.cancel()
                    settling = nil
                    drag = (kind, layout.geometry.cropRect(for: layout.photo), layout.geometry)
                    stopped = false
                    freeze = layout
                    onEditing(true)
                    #if os(macOS)
                    if kind == .move { NSCursor.closedHand.set() }
                    #endif
                }
                guard let drag else { return }
                let (geometry, stop) = dragged(drag, by: value.translation)
                if stop, !stopped { stops += 1 }
                stopped = stop
                write(geometry)
            }
            .onEnded { value in
                guard let drag else { return }
                let (geometry, _) = dragged(drag, by: value.translation)
                #if os(macOS)
                Self.cursor(CropDrag.at(value.location, box: (freeze ?? layout).with(geometry).cropRect)).set()
                #endif
                endDrag(with: geometry)
            }
    }

    /// Ends a drag once, however it ends: with the finger's last geometry, or
    /// (cancelled) with what was last written. Then the canvas fits the crop.
    private func endDrag(with geometry: Geometry?) {
        guard drag != nil else { return }
        if let geometry { write(geometry) }
        drag = nil
        stopped = false
        finishEditing()
        settle(from: freeze ?? layout, to: geometry ?? layout.geometry)
    }

    /// The one place a crop drag is closed (the host's `editingGeometry(false)`,
    /// or the editor's close-out call for interactions once it has one).
    private func finishEditing() {
        onEditing(false)
    }

    /// The geometry a drag leaves after the finger moved `translation` points,
    /// and whether the photo's edge held it back.
    private func dragged(_ drag: (kind: CropDrag, start: GeometryRect, geometry: Geometry),
                         by translation: CGSize) -> (Geometry, stopped: Bool) {
        // A press that has not moved changes nothing (an automatic crop stays automatic).
        guard translation != .zero else { return (drag.geometry, false) }
        let scale = (freeze ?? layout).scale
        let delta = GeometryPoint(x: Double(translation.width) / scale, y: Double(translation.height) / scale)
        let frame = drag.geometry.frameSize(of: layout.photo)
        let ratio = drag.geometry.aspect == .free ? nil
            : drag.geometry.aspect.ratio(frame: frame) ?? drag.start.width / drag.start.height
        let result = drag.kind.resolve(delta, to: drag.start, ratio: ratio, quad: drag.geometry.quad(for: layout.photo),
                                       minimum: max(frame.width, frame.height) * 0.06)
        var geometry = drag.geometry
        geometry.crop = CropRect(centre: result.rect.centre, size: result.rect.size, frame: frame)
        return (geometry, result.stopped)
    }

    /// The largest crop of the ratio in force, centred: what the box is with
    /// no crop of its own.
    private func resetCrop() {
        guard drag == nil, layout.geometry.crop != nil else { return }
        var geometry = layout.geometry
        geometry.crop = nil
        let from = freeze ?? layout
        settling?.cancel()
        settling = nil
        // Held where it is while the crop changes, then fitted.
        freeze = from
        write(geometry)
        resets += 1
        settle(from: from, to: geometry)
    }

    /// Glides the canvas from `start`'s placement to the one that fits
    /// `geometry`'s crop, then lets the pane fit it as usual.
    private func settle(from start: CropLayout, to geometry: Geometry) {
        settling?.cancel()
        let held = start.with(geometry), target = held.fitted
        guard !reduceMotion, !held.settles(at: target) else {
            settling = nil
            freeze = nil
            return
        }
        freeze = held
        settling = Task { @MainActor in
            let clock = ContinuousClock(), began = clock.now
            while !Task.isCancelled {
                let t = min(1, (clock.now - began) / .seconds(Self.settleDuration))
                if t >= 1 { break }
                // Ease out: quick at first, landing softly.
                freeze = held.moving(towards: target, 1 - pow(1 - t, 3))
                try? await Task.sleep(for: .milliseconds(8))
            }
            guard !Task.isCancelled else { return }
            freeze = nil
            settling = nil
        }
    }
}

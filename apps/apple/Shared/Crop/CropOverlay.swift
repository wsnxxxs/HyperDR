import HyperDRDesign
import HyperDRRecipe
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Over the canvas in the crop pane: the crop box with its corners and the
/// middles of its edges, thirds while it is dragged and a finer grid while
/// the photo is straightened or its perspective corrected. The canvas dims the
/// photo outside it (`GeometryDisplay.dimsOutsideCrop`), in linear light, so
/// HDR highlights dim too.
///
/// - A corner or an edge resizes the box, its size in pixels showing under it;
///   inside it the photo moves under the box, which stays where it is (as in
///   Photos). A fixed ratio holds while resizing (Free lets each edge go its
///   own way). A finger takes hold of an edge within `CropDrag.reach` of it.
/// - The box never leaves the photo: a drag stops where the photo ends, with a
///   tap of the haptics (iOS) or the trackpad (Mac) when it does.
/// - While the box is resized the photo stays where it is (`freeze`); when
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
    /// Ends the crop gesture that never reported its end (cancelled, or the
    /// overlay gone): the editor's `endCropInteraction()`, which commits it
    /// as one undo step.
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CropDragState?
    /// The geometry when something in the pane started being dragged, so the
    /// grid can tell straightening and perspective from the rest.
    @State private var adjustingFrom: Geometry?
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
        let showsFine = drag == nil && transforms
        let showsThirds = (drag != nil || adjusting) && !showsFine
        ZStack {
            thirds(box)
                .opacity(showsThirds ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: showsThirds)
            grid(box)
                .opacity(showsFine ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: showsFine)
            Rectangle()
                .path(in: box)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
            handles(box)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .square))
            if case .resize? = drag?.kind { sizeTag(box) }
        }
        .contentShape(.rect)
        .onChange(of: adjusting, initial: true) { _, now in adjustingFrom = now ? layout.geometry : nil }
        .gesture(gesture(box))
        // A cancelled drag (a system gesture, the view rebuilt) ends as a finished one.
        .onChange(of: pressing) { _, now in if !now { endDrag(with: nil, cancelled: true) } }
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
                finishEditing(cancelled: true)
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

    /// The straightening or the perspective is being dragged (a slider, a ring).
    private var transforms: Bool {
        guard adjusting, let from = adjustingFrom else { return false }
        let now = layout.geometry
        return from.angle != now.angle || from.vertical != now.vertical || from.horizontal != now.horizontal
    }

    /// Square cells of about `CropOverlay.gridSpacing`, for lining up
    /// horizons and verticals while straightening.
    private func grid(_ box: CGRect) -> some View {
        let columns = max(3, Int((box.width / Self.gridSpacing).rounded()))
        let rows = max(3, Int((box.height / Self.gridSpacing).rounded()))
        return Path { path in
            for i in 1..<columns {
                let x = box.minX + box.width * CGFloat(i) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
            }
            for i in 1..<rows {
                let y = box.minY + box.height * CGFloat(i) / CGFloat(rows)
                path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
    }

    static let gridSpacing: CGFloat = 44

    /// The crop's size in pixels while the box is resized: under the box, or
    /// inside its foot when the canvas ends below it.
    private func sizeTag(_ box: CGRect) -> some View {
        let size = layout.geometry.outputSize(of: layout.photo)
        let below = box.maxY + Self.sizeTagGap + Self.sizeTagHeight <= layout.viewport.height
        let y = below ? box.maxY + Self.sizeTagGap + Self.sizeTagHeight / 2
            : box.maxY - Self.sizeTagGap - Self.sizeTagHeight / 2
        return Text(verbatim: "\(size.width) × \(size.height)")
            .monospacedDigit()
            .fixedSize()
            .hdrOverlayChip()
            .position(x: box.midX, y: y)
            .allowsHitTesting(false)
    }

    private static let sizeTagGap: CGFloat = 10
    private static let sizeTagHeight: CGFloat = 24

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
                    drag = CropDragState(kind: kind, start: layout.geometry.cropRect(for: layout.photo),
                                         geometry: layout.geometry, layout: layout)
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
                // Moving: the photo follows the pointer under a box that stays.
                if drag.kind == .move { freeze = drag.layout.following(geometry) }
            }
            .onEnded { value in
                guard let drag else { return }
                let (geometry, _) = dragged(drag, by: value.translation)
                #if os(macOS)
                Self.cursor(CropDrag.at(value.location, box: (freeze ?? layout).with(geometry).cropRect)).set()
                #endif
                endDrag(with: geometry, cancelled: false)
            }
    }

    /// Ends a drag once, however it ends: with the finger's last geometry, or
    /// (cancelled) with what was last written. Then the canvas fits the crop.
    private func endDrag(with geometry: Geometry?, cancelled: Bool) {
        guard let current = drag else { return }
        if let geometry {
            write(geometry)
            if current.kind == .move { freeze = current.layout.following(geometry) }
        }
        drag = nil
        stopped = false
        finishEditing(cancelled: cancelled)
        settle(from: freeze ?? layout, to: geometry ?? layout.geometry)
    }

    /// Closes the crop drag in the editor. A cancelled one is committed by
    /// `onCancel`; the end notice after it then clears the editor's guard
    /// against the gesture's late writes, so the next edit is not dropped.
    private func finishEditing(cancelled: Bool) {
        if cancelled { onCancel() }
        onEditing(false)
    }

    /// The geometry a drag leaves after the finger moved `translation` points,
    /// and whether the photo's edge held it back.
    private func dragged(_ drag: CropDragState, by translation: CGSize) -> (Geometry, stopped: Bool) {
        // A press that has not moved changes nothing (an automatic crop stays automatic).
        guard translation != .zero else { return (drag.geometry, false) }
        // The photo follows the pointer, so the crop moves the other way over it.
        let scale = drag.layout.scale, sign = drag.kind == .move ? -1.0 : 1.0
        let delta = GeometryPoint(x: sign * Double(translation.width) / scale, y: sign * Double(translation.height) / scale)
        let frame = drag.geometry.frameSize(of: layout.photo)
        let ratio = drag.geometry.aspect == .free ? nil
            : drag.geometry.aspect.ratio(frame: frame) ?? drag.start.width / drag.start.height
        let result = drag.kind.resolve(delta, to: drag.start, ratio: ratio, quad: drag.geometry.quad(for: layout.photo),
                                       minimum: max(frame.width, frame.height) * 0.06)
        let geometry = drag.geometry.settingCrop(CropRect(centre: result.rect.centre, size: result.rect.size, frame: frame),
                                                 photo: layout.photo)
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

/// A drag of the crop box under way: what it took hold of, the crop and the
/// geometry it started from, and where the pane had the photo then.
private struct CropDragState {
    let kind: CropDrag
    let start: GeometryRect
    let geometry: Geometry
    let layout: CropLayout
}

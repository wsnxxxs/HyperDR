import HyperDRRender
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The iOS host of the shared canvas: a `CAMetalLayer` in extended linear
/// Display P3 drawn by the shared `DisplayCompositor`, pinch to zoom, drag to
/// pan, double tap to switch between fit and actual pixels, and a press of
/// 240 ms to see the original (p7-adjustments §5.4). The photo can be shown
/// edited, original or split, with detail tiles
/// (step 6); every change of geometry is reported through `onTransform`, for
/// the overlays and the editor's viewport. Headroom is read from
/// the window's `UIScreen` on every display tick; when it moves only the
/// display weight changes, the photo is not rendered again (p7-2b §5).
final class EDRCanvasUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onHeadroom: (HeadroomSnapshot) -> Void = { _ in }
    var onDrawableSize: (HyperDRRender.PixelSize) -> Void = { _ in }
    var onHoldOriginal: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    var onTransform: (CanvasTransform) -> Void = { _ in }

    /// What to show; the pairs come from Render through `RecipeEditor`.
    struct Content {
        var edited: DisplayPair
        var original: DisplayPair?
        var editedDetail: DisplayPair?
        var originalDetail: DisplayPair?
        /// `.original` and `.compare` need `original`; without it the edit shows.
        var mode: DisplayComposition.Mode = .edited
        var splitRatio = 0.5
        var previewsAsSDR = false
        /// The photo's full oriented size, for actual pixels and detail regions.
        var imageSize: CGSize
        /// The crop pane draws the photo through its geometry; the canvas's own
        /// zoom, pan and hold are off meanwhile.
        var geometry: GeometryDisplay? = nil
    }

    var content: Content? {
        didSet {
            if oldValue?.imageSize != content?.imageSize {
                geometry = CanvasTransform(imageSize: content?.imageSize ?? .zero, viewport: bounds.size)
                geometry.backingScale = contentScaleFactor
            }
            dirty = true
        }
    }

    private let queue: (any MTLCommandQueue)?
    private let compositor: DisplayCompositor?
    private var headroom = HeadroomSnapshot()
    private var geometry = CanvasTransform(imageSize: .zero, viewport: .zero)
    private var reported: CanvasTransform?
    private var link: CADisplayLink?
    private var dirty = true
    private var inFlight = false

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        let queue = device?.makeCommandQueue()
        var compositor: DisplayCompositor?
        var failure: String?
        if let device, queue != nil, let library = device.makeDefaultLibrary() {
            do { compositor = try DisplayCompositor(device: device, library: library) } catch { failure = error.localizedDescription }
        } else {
            failure = "No Metal device"
        }
        self.queue = queue
        self.compositor = compositor
        super.init(frame: frame)
        if let device { EDRDisplayPass.configure(metalLayer, device: device) }
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        addGestures()
        if let failure { DispatchQueue.main.async { [weak self] in self?.onError(failure) } }
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Window and layout

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return }
        contentScaleFactor = window.screen.scale
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
        dirty = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        geometry.viewport = bounds.size
        geometry.backingScale = contentScaleFactor
        geometry.pan = geometry.clampedPan(geometry.pan)
        let size = CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor)
        metalLayer.drawableSize = size
        if size.width >= 1, size.height >= 1 {
            onDrawableSize(HyperDRRender.PixelSize(width: Int(size.width), height: Int(size.height)))
        }
        dirty = true
    }

    // MARK: - Display tick

    /// Geometry is reported on the display tick, outside SwiftUI's updates.
    @objc private func step() {
        if geometry != reported {
            reported = geometry
            onTransform(geometry)
        }
        sampleHeadroom()
        guard dirty, !inFlight else { return }
        draw()
    }

    private func sampleHeadroom() {
        guard let screen = window?.windowScene?.screen else { return }
        let next = HeadroomSnapshot(screen: nil, current: screen.currentEDRHeadroom,
                                    potential: screen.potentialEDRHeadroom)
        guard next != headroom else { return }
        headroom = next
        onHeadroom(next)
        dirty = true
    }

    /// Draws the newest state, one presentation in flight at a time. Without
    /// content the canvas is cleared.
    private func draw() {
        guard let queue, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(), let command = queue.makeCommandBuffer() else { return }
        dirty = false
        inFlight = true
        var drawn = false
        if let content, let compositor {
            var composition = DisplayComposition(edited: content.edited, headroom: Double(max(1, headroom.current)))
            composition.editedDetail = content.editedDetail
            composition.previewsAsSDR = content.previewsAsSDR
            composition.splitRatio = content.splitRatio
            composition.geometry = content.geometry
            if let original = content.original, content.geometry == nil {
                composition.original = original
                composition.originalDetail = content.originalDetail
                composition.mode = content.mode
            }
            do {
                try compositor.encode(composition, transform: geometry, target: drawable.texture, command: command)
                drawn = true
            } catch {
                onError(error.localizedDescription)
            }
        }
        if !drawn, let encoder = command.makeRenderCommandEncoder(descriptor: EDRDisplayPass.clearPass(drawable)) {
            encoder.endEncoding()
        }
        // Metal calls this on its own thread: not main-actor isolated.
        command.addCompletedHandler { @Sendable [weak self] _ in
            Task { @MainActor in self?.inFlight = false }
        }
        command.present(drawable)
        command.commit()
    }

    // MARK: - Gestures

    private func addGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.24
        for recognizer in [pinch, pan, doubleTap, hold] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    /// The crop pane has the canvas's touches.
    private var cropping: Bool { content?.geometry != nil }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard !cropping, recognizer.state == .changed || recognizer.state == .ended else { return }
        apply(geometry.zoomed(to: geometry.zoom * recognizer.scale, anchorInView: recognizer.location(in: self)))
        recognizer.scale = 1
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard !cropping else { return }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        apply(geometry.panned(by: CGSize(width: delta.x, height: delta.y)))
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard !cropping else { return }
        let target = geometry.zoom > CanvasTransform.minZoom ? CanvasTransform.minZoom
            : min(geometry.maxZoom, max(2, geometry.actualPixelsZoom))
        apply(geometry.zoomed(to: target, anchorInView: recognizer.location(in: self)))
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: if !cropping { onHoldOriginal(true) }
        case .ended, .cancelled, .failed: onHoldOriginal(false)
        default: break
        }
    }

    /// Back to the whole photo, fitted.
    func fit() {
        var next = CanvasTransform(imageSize: geometry.imageSize, viewport: bounds.size)
        next.backingScale = contentScaleFactor
        apply(next)
    }

    /// One photo pixel to one screen pixel, about the middle of the view; a
    /// photo smaller than the view stays fitted.
    func zoomToActualPixels() {
        guard !cropping else { return }
        let target = min(geometry.maxZoom, max(CanvasTransform.minZoom, geometry.actualPixelsZoom))
        apply(geometry.zoomed(to: target, anchorInView: CGPoint(x: bounds.midX, y: bounds.midY)))
    }

    private func apply(_ next: CanvasTransform) {
        guard next != geometry else { return }
        geometry = next
        dirty = true
    }
}

extension EDRCanvasUIView: UIGestureRecognizerDelegate {
    /// Pinch and two-finger pan run together, so a pinch can also move the photo.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A request to fit the photo or show it at actual pixels (the iPad's canvas
/// bar and ⌘0). Each request is new, so asking twice for the same kind
/// works twice.
struct CanvasZoomRequest: Equatable {
    enum Kind { case fit, actualPixels }
    let kind: Kind
    let id = UUID()
}

/// SwiftUI wrapper of `EDRCanvasUIView`.
struct EDRCanvas: UIViewRepresentable {
    var content: EDRCanvasUIView.Content?
    /// A change fits the whole photo again (entering or leaving the frame view).
    var fitRequest = false
    /// A new request zooms; the one current when the canvas is made is not run.
    var zoomRequest: CanvasZoomRequest? = nil
    var onHeadroom: (HeadroomSnapshot) -> Void
    var onDrawableSize: (HyperDRRender.PixelSize) -> Void
    var onHoldOriginal: (Bool) -> Void
    var onError: (String) -> Void
    var onTransform: (CanvasTransform) -> Void

    final class Coordinator {
        var fitRequest: Bool?
        var zoomRequest: CanvasZoomRequest?
        var hasSeenZoomRequest = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> EDRCanvasUIView {
        let view = EDRCanvasUIView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: EDRCanvasUIView, context: Context) {
        view.onHeadroom = onHeadroom
        view.onDrawableSize = onDrawableSize
        view.onHoldOriginal = onHoldOriginal
        view.onError = onError
        view.onTransform = onTransform
        if !Self.same(view.content, content) { view.content = content }
        if let last = context.coordinator.fitRequest, last != fitRequest { view.fit() }
        context.coordinator.fitRequest = fitRequest
        if context.coordinator.hasSeenZoomRequest, let request = zoomRequest, request != context.coordinator.zoomRequest {
            switch request.kind {
            case .fit: view.fit()
            case .actualPixels: view.zoomToActualPixels()
            }
        }
        context.coordinator.zoomRequest = zoomRequest
        context.coordinator.hasSeenZoomRequest = true
    }

    private static func same(_ a: EDRCanvasUIView.Content?, _ b: EDRCanvasUIView.Content?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        func same(_ x: DisplayPair?, _ y: DisplayPair?) -> Bool {
            x.flatMap { left in y.map { left.hasSameContent(as: $0) } } ?? (x == nil && y == nil)
        }
        return a.edited.hasSameContent(as: b.edited) && same(a.original, b.original)
            && same(a.editedDetail, b.editedDetail) && same(a.originalDetail, b.originalDetail)
            && a.mode == b.mode && a.splitRatio == b.splitRatio && a.previewsAsSDR == b.previewsAsSDR
            && a.imageSize == b.imageSize && a.geometry == b.geometry
    }
}

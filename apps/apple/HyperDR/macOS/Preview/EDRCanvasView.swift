import AppKit
import CoreGraphics
import HyperDREngine
import Metal
import QuartzCore

/// The photo surface. It draws only the photo rect (everything else stays
/// transparent), owns zoom/pan gestures, and never becomes first responder:
/// keyboard handling belongs to the view layer and the menu commands (§3.5).
@MainActor
final class EDRCanvasView: NSView {
    /// Draws on its own thread; this view only hands it snapshots (A2b-2).
    private(set) var renderLoop: PreviewRenderLoop?
    private let onHeadroom: (HeadroomSnapshot) -> Void
    private let onError: (String) -> Void
    private let headroom = HeadroomMonitor()
    private var isSuspended = false
    private let headroomPolicy = HeadroomPolicy.configured
    private var link: CADisplayLink?
    private var dirty = true
    private var generation: UInt64 = 0
    private var dragOrigin: CGPoint?

    /// Supplies the frame to draw. A2 wires this to the live preview service;
    /// the diagnostic window supplies a synthetic ramp instead.
    var compositionProvider: (() -> CanvasComposition?)?
    var frameProvider: (() -> PreviewCanvasFrame?)?
    /// Called when a gesture changed the transform; the representable mirrors
    /// it into `CanvasModel` so overlays stay aligned.
    /// Raw pointer events for the view layer's press-and-hold (§3.5): points in
    /// this view, top-left origin. The canvas keeps its own pan and zoom.
    var onPointerDown: ((CGPoint) -> Void)?
    var onPointerDrag: ((CGPoint) -> Void)?
    var onPointerUp: (() -> Void)?
    /// The wheel or a pinch acted on the canvas.
    var onZoomGesture: (() -> Void)?
    var onTransformChange: ((CanvasTransform) -> Void)?
    /// Called when the view itself knows the viewport size (layout, backing
    /// scale). Keeps `CanvasModel.imageFrame` alive without echoing the frame's
    /// own dimensions back into the model.
    var onViewportChange: ((CGSize, Double) -> Void)?
    var onRefreshRateChange: ((Int) -> Void)?
    /// Geometry the canvas draws with: fit, zoom and pan in view points.
    var transform = CanvasTransform(imageSize: .zero, viewport: .zero) {
        didSet {
            guard transform != oldValue else { return }
            updateDrawableSize()
            setNeedsRedraw()
        }
    }

    /// Fixed synthetic content (diagnostic window); photo canvases leave it nil.
    var showsSyntheticRamp = false {
        didSet { setNeedsRedraw() }
    }

    var showsOriginal = false {
        didSet { setNeedsRedraw() }
    }

    /// Off for a canvas that only presents the fitted photo (the frame sheet).
    var allowsZoom = true

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// `renderer` is a test seam; the app lets the view build its own.
    init(renderer suppliedRenderer: PreviewRenderer? = nil,
         onHeadroom: @escaping (HeadroomSnapshot) -> Void = { _ in },
         onError: @escaping (String) -> Void = { _ in }) {
        self.onHeadroom = onHeadroom
        self.onError = onError
        super.init(frame: .zero)
        wantsLayer = true
        do {
            let renderer = try suppliedRenderer ?? PreviewRenderer()
            metalLayer.device = renderer.device
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
            // Only the photo rect is opaque; the rest of the canvas is clear so
            // the SwiftUI backdrop shows through.
            metalLayer.isOpaque = false
            metalLayer.framebufferOnly = true
            // AppKit owns contentsScale; the loop updates only drawableSize
            // between draws from immutable geometry snapshots.
            renderLoop = PreviewRenderLoop(renderer: renderer, layer: metalLayer) { [weak self] message in
                MainActor.assumeIsolated { self?.onError(message) }
            }
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onError(message) }
        }
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit { renderLoop?.stop() }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
        guard let window else { suspend(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        refreshDisplay()
        visibilityChanged()
    }

    override func viewDidHide() {
        super.viewDidHide()
        suspend()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        // Rebuild on the next visible tick, never from a visibility callback.
        isSuspended = false
        setNeedsRedraw()
    }

    @objc private func visibilityChanged() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              window?.occlusionState.contains(.visible) == true else { suspend(); return }
        isSuspended = false
        setNeedsRedraw()
    }

    override func layout() {
        super.layout()
        transform.viewport = bounds.size
        updateDrawableSize()
        onViewportChange?(bounds.size, Double(transform.backingScale))
        setNeedsRedraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        onViewportChange?(bounds.size, Double(transform.backingScale))
        refreshDisplay()
    }

    /// Only the geometry the next snapshot carries; the render loop resizes
    /// the layer itself, between draws.
    private func updateDrawableSize() {
        transform.backingScale = window?.backingScaleFactor ?? 1
    }

    @objc private func step(_ link: CADisplayLink) {
        let interval = PreviewRenderer.signposter.beginInterval("CanvasTick")
        defer { PreviewRenderer.signposter.endInterval("CanvasTick", interval) }
        refreshDisplay()
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              window?.occlusionState.contains(.visible) == true else { suspend(); return }
        if isSuspended { isSuspended = false; setNeedsRedraw() }
        tick()
    }

    /// One display tick: if anything changed, capture a snapshot and hand it
    /// to the render loop. Never draws, waits for a drawable or touches the
    /// layer; the loop keeps only the newest snapshot and draws it once the
    /// GPU has finished the previous one.
    func tick() {
        guard dirty, let renderLoop else { return }
        dirty = false
        let content: CanvasSnapshot.Content
        if var composition = compositionProvider?() {
            if window != nil { composition.headroom = headroomPolicy.target(headroom.snapshot) }
            if headroomPolicy == .declaredCurrent {
                metalLayer.preferredDynamicRange = .high
                metalLayer.contentsHeadroom = max(1, exp2(max(composition.edited.metadata.headroomStops, composition.original?.metadata.headroomStops ?? 0)))
            }
            content = .composition(composition)
        } else if let frame = frameProvider?() {
            content = .frame(frame.frame, original: frame.showsOriginal)
        } else if showsSyntheticRamp {
            if transform.imageSize == .zero { showImageSize(PreviewRenderer.syntheticRampSize) }
            content = .synthetic(original: showsOriginal)
        } else {
            // Closing the photo must not leave the last frame on screen.
            content = .empty
        }
        generation += 1
        let scale = transform.backingScale
        PreviewRenderer.signposter.emitEvent("Handoff")
        renderLoop.submit(CanvasSnapshot(content: content, transform: transform,
            drawableSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            generation: generation))
    }

    func setNeedsRedraw() { dirty = true }
    var needsRedraw: Bool { dirty }
    /// The generation of the last snapshot handed to the render loop.
    var handedOverGeneration: UInt64 { generation }

    /// Adopts the frame's own dimensions once, without echoing geometry back to
    /// the model (that would fight `updateNSView`).
    private func showImageSize(_ size: CGSize) {
        guard size != transform.imageSize else { return }
        transform.imageSize = size
    }

    @objc private func displayChanged() { refreshDisplay(force: true) }

    private func refreshDisplay(force: Bool = false) {
        updateDrawableSize()
        let changed = headroom.sample(window?.screen)
        if let screen = window?.screen { onRefreshRateChange?(screen.maximumFramesPerSecond) }
        if changed || force {
            setNeedsRedraw()
            onHeadroom(headroom.snapshot)
        }
    }

    private func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        dirty = true
        renderLoop?.submit(CanvasSnapshot(content: .suspended, transform: transform,
            drawableSize: .zero, generation: generation))
    }

    // MARK: - Gestures

    /// Wheel zooms, anchored at the pointer, exactly like `view.js`.
    override func scrollWheel(with event: NSEvent) {
        guard allowsZoom else { return super.scrollWheel(with: event) }
        onZoomGesture?()
        // Line-based wheels report small deltas; the Web editor scales those by
        // 16 (`deltaMode === 1`) so a notch feels the same as a trackpad slide.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
        guard let next = transform.wheelZoom(fromZoom: transform.zoom,
                deltaY: -delta, ctrl: event.modifierFlags.contains(.control)) else { return }
        applyZoom(next, anchor: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard allowsZoom else { return super.magnify(with: event) }
        onZoomGesture?()
        applyZoom(transform.zoom * (1 + event.magnification),
                  anchor: convert(event.locationInWindow, from: nil))
    }

    private func applyZoom(_ factor: Double, anchor: CGPoint) {
        let next = transform.zoomed(to: factor, anchorInView: anchor)
        guard next != transform else { return }
        transform = next
        onTransformChange?(next)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?(convert(event.locationInWindow, from: nil))
        guard allowsZoom, transform.zoom > CanvasTransform.minZoom else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onPointerDrag?(point)
        guard let origin = dragOrigin else { return }
        let next = transform.panned(by: CGSize(width: point.x - origin.x,
                                               height: point.y - origin.y))
        dragOrigin = point
        guard next != transform else { return }
        transform = next
        onTransformChange?(next)
    }

    override func mouseUp(with event: NSEvent) {
        onPointerUp?()
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: transform.zoom > CanvasTransform.minZoom
            ? .openHand : .arrow)
    }
}

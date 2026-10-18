import AppKit
import CoreGraphics
import HyperDREngine
import Metal
import QuartzCore

struct HeadroomSnapshot: Equatable {
    var screen = "waiting for display"
    var current: CGFloat = 1
    var potential: CGFloat = 1
    var reference: CGFloat = 1
}

/// The photo surface. It draws only the photo rect (everything else stays
/// transparent), owns zoom/pan gestures, and never becomes first responder:
/// keyboard handling belongs to the view layer and the menu commands (§3.5).
@MainActor
final class EDRCanvasView: NSView {
    private var renderer: PreviewRenderer?
    private let onHeadroom: (HeadroomSnapshot) -> Void
    private let onError: (String) -> Void
    private var lastSnapshot: HeadroomSnapshot?
    private var displayTimer: Timer?
    private var link: CADisplayLink?
    private var dirty = true
    private var cleared = false
    private var dragOrigin: CGPoint?
    private var synthetic: FramePlanes?

    /// Supplies the frame to draw. A2 wires this to the live preview service;
    /// the diagnostic window supplies a synthetic ramp instead.
    var frameProvider: (() -> PreviewCanvasFrame?)?
    /// Called when a gesture changed the transform; the representable mirrors
    /// it into `CanvasModel` so overlays stay aligned.
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

    init(onHeadroom: @escaping (HeadroomSnapshot) -> Void = { _ in },
         onError: @escaping (String) -> Void = { _ in }) {
        self.onHeadroom = onHeadroom
        self.onError = onError
        super.init(frame: .zero)
        wantsLayer = true
        do {
            let renderer = try PreviewRenderer()
            self.renderer = renderer
            metalLayer.device = renderer.device
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
            // Only the photo rect is opaque; the rest of the canvas is clear so
            // the SwiftUI backdrop shows through.
            metalLayer.isOpaque = false
            metalLayer.framebufferOnly = true
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onError(message) }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: - Window lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayTimer?.invalidate()
        displayTimer = nil
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        // A poll covers display reconfiguration and headroom changes that do
        // not coincide with a redraw.
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplay() }
        }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        refreshDisplay()
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

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        transform.backingScale = scale
    }

    @objc private func step(_ link: CADisplayLink) {
        guard dirty, window?.isVisible == true else { return }
        dirty = false
        render()
        if renderer?.needsRetry == true { dirty = true }
    }

    func setNeedsRedraw() { dirty = true }

    // MARK: - Drawing

    private func render() {
        guard let renderer else { return }
        do {
            if let frame = frameProvider?() {
                try renderer.prepare(frame: frame.frame, original: frame.showsOriginal)
                cleared = false
            } else if showsSyntheticRamp {
                if synthetic == nil { synthetic = try PreviewRenderer.syntheticRamp(device: renderer.device) }
                if let synthetic {
                    try renderer.prepare(planes: synthetic, original: showsOriginal)
                    if transform.imageSize == .zero {
                        showImageSize(CGSize(width: synthetic.width, height: synthetic.height))
                    }
                    cleared = false
                }
            } else {
                // Closing the photo must not leave the last frame on screen: the
                // layer keeps its last drawable until something presents again.
                if !cleared { cleared = renderer.clear(in: metalLayer) }
                return
            }
            renderer.draw(in: metalLayer, transform: transform)
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onError(message) }
        }
    }

    /// Adopts the frame's own dimensions once, without echoing geometry back to
    /// the model (that would fight `updateNSView`).
    private func showImageSize(_ size: CGSize) {
        guard size != transform.imageSize else { return }
        transform.imageSize = size
    }

    private func refreshDisplay() {
        updateDrawableSize()
        if let screen = window?.screen {
            onRefreshRateChange?(screen.maximumFramesPerSecond)
            let snapshot = HeadroomSnapshot(screen: screen.localizedName,
                current: screen.maximumExtendedDynamicRangeColorComponentValue,
                potential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                reference: screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                DispatchQueue.main.async { [weak self] in self?.onHeadroom(snapshot) }
            }
        }
    }

    // MARK: - Gestures

    /// Wheel zooms, anchored at the pointer, exactly like `view.js`.
    override func scrollWheel(with event: NSEvent) {
        guard allowsZoom else { return super.scrollWheel(with: event) }
        // Line-based wheels report small deltas; the Web editor scales those by
        // 16 (`deltaMode === 1`) so a notch feels the same as a trackpad slide.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 16
        guard let next = CanvasTransform.wheelZoom(fromZoom: transform.zoom,
                deltaY: -delta, ctrl: event.modifierFlags.contains(.control)) else { return }
        applyZoom(next, anchor: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard allowsZoom else { return super.magnify(with: event) }
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
        guard allowsZoom, transform.zoom > CanvasTransform.minZoom else { return }
        dragOrigin = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = transform.panned(by: CGSize(width: point.x - origin.x,
                                               height: point.y - origin.y))
        dragOrigin = point
        guard next != transform else { return }
        transform = next
        onTransformChange?(next)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin = nil
        NSCursor.openHand.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: transform.zoom > CanvasTransform.minZoom
            ? .openHand : .arrow)
    }
}

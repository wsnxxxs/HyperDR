import HyperDRRender
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The iOS host of the shared canvas: a `CAMetalLayer` in extended linear
/// Display P3 drawn by the shared `DisplayCompositor`, pinch to zoom, drag to
/// pan, double tap to switch between fit and actual pixels, and a press of
/// 240 ms to see the original (p7-adjustments §5.4). Headroom is read from
/// the window's `UIScreen` on every display tick; when it moves only the
/// display weight changes, the photo is not rendered again (p7-2b §5).
final class EDRCanvasUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onHeadroom: (HeadroomSnapshot) -> Void = { _ in }
    var onDrawableSize: (HyperDRRender.PixelSize) -> Void = { _ in }
    var onHoldOriginal: (Bool) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    /// What to show; the pairs come from Render through `RecipeEditor`.
    struct Content {
        var edited: DisplayPair
        var original: DisplayPair?
        var showsOriginal = false
        /// The photo's full oriented size, for actual pixels.
        var imageSize: CGSize
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

    @objc private func step() {
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
            if content.showsOriginal, let original = content.original {
                composition.original = original
                composition.mode = .original
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

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed || recognizer.state == .ended else { return }
        apply(geometry.zoomed(to: geometry.zoom * recognizer.scale, anchorInView: recognizer.location(in: self)))
        recognizer.scale = 1
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        apply(geometry.panned(by: CGSize(width: delta.x, height: delta.y)))
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        let target = geometry.zoom > CanvasTransform.minZoom ? CanvasTransform.minZoom
            : min(geometry.maxZoom, max(2, geometry.actualPixelsZoom))
        apply(geometry.zoomed(to: target, anchorInView: recognizer.location(in: self)))
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onHoldOriginal(true)
        case .ended, .cancelled, .failed: onHoldOriginal(false)
        default: break
        }
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

extension DisplayPair {
    /// Render's display pair (R3) as the shared compositor takes it. A pair
    /// covering its whole output is the preview; one with a smaller region is a
    /// detail layer at that place.
    init(_ pair: DisplayGainPair) {
        let whole = CGRect(x: 0, y: 0, width: pair.outputSize.width, height: pair.outputSize.height)
        self.init(base: pair.base, gain: pair.gain, coding: .log2,
                  baseOffset: pair.baseOffset, alternateOffset: pair.alternateOffset,
                  toGain: pair.p3ToGain, toP3: pair.gainToP3,
                  baseHeadroom: Double(pair.baseHeadroom), alternateHeadroom: Double(pair.alternateHeadroom),
                  region: pair.region == whole ? nil : pair.region)
    }
}

/// SwiftUI wrapper of `EDRCanvasUIView`.
struct EDRCanvas: UIViewRepresentable {
    var content: EDRCanvasUIView.Content?
    var onHeadroom: (HeadroomSnapshot) -> Void
    var onDrawableSize: (HyperDRRender.PixelSize) -> Void
    var onHoldOriginal: (Bool) -> Void
    var onError: (String) -> Void

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
        if !Self.same(view.content, content) { view.content = content }
    }

    private static func same(_ a: EDRCanvasUIView.Content?, _ b: EDRCanvasUIView.Content?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let originals = a.original.flatMap { left in b.original.map { left.hasSameContent(as: $0) } }
            ?? (a.original == nil && b.original == nil)
        return a.edited.hasSameContent(as: b.edited) && originals
            && a.showsOriginal == b.showsOriginal && a.imageSize == b.imageSize
    }
}

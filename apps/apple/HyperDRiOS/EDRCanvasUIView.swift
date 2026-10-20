import CoreImage
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// The iOS host of the shared EDR display pass: a `CAMetalLayer` in extended
/// linear Display P3, pinch to zoom, drag to pan, double tap to switch between
/// fit and actual pixels. Headroom is read from the window's `UIScreen` on
/// every display tick; when it moves, the photo is rendered again for it.
final class EDRCanvasUIView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onHeadroom: (HeadroomSnapshot) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }

    var photo: HDRPhoto? {
        didSet {
            texture = nil
            renderedHeadroom = nil
            geometry = CanvasTransform(imageSize: photo?.size ?? .zero, viewport: bounds.size)
            geometry.backingScale = contentScaleFactor
            renderGeneration += 1
            dirty = true
        }
    }

    private let queue: (any MTLCommandQueue)?
    private let display: EDRDisplayPass?
    private let context: CIContext?
    private var texture: (any MTLTexture)?
    /// The display headroom `texture` was rendered for; nil while none is.
    private var renderedHeadroom: CGFloat?
    private var renderGeneration = 0
    private var rendering = false
    private var headroom = HeadroomSnapshot()
    private var geometry = CanvasTransform(imageSize: .zero, viewport: .zero)
    private var link: CADisplayLink?
    private var dirty = true
    private var inFlight = false

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        let queue = device?.makeCommandQueue()
        var display: EDRDisplayPass?
        var failure: String?
        if let device, queue != nil, let library = device.makeDefaultLibrary() {
            do { display = try EDRDisplayPass(device: device, library: library) } catch { failure = error.localizedDescription }
        } else {
            failure = "No Metal device"
        }
        self.queue = queue
        self.display = display
        context = queue.map(TemporaryHDRSource.makeContext)
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
        metalLayer.drawableSize = CGSize(width: bounds.width * contentScaleFactor,
                                         height: bounds.height * contentScaleFactor)
        dirty = true
    }

    // MARK: - Display tick

    @objc private func step() {
        sampleHeadroom()
        renderIfNeeded()
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
    }

    /// Renders the photo again when the headroom it is shown at moved by more
    /// than 0.02 stops, one render at a time, newest photo wins. Past the
    /// photo's own headroom nothing changes, so that is where it stops.
    private func renderIfNeeded() {
        guard let photo, let context, let queue, !rendering else { return }
        let target = min(max(1, headroom.current), photo.headroom)
        if let renderedHeadroom, abs(log2(target / renderedHeadroom)) < 0.02 { return }
        rendering = true
        let generation = renderGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try TemporaryHDRSource.render(photo, displayHeadroom: target, context: context, queue: queue) }
            await self?.finishRender(result, headroom: target, generation: generation)
        }
    }

    private func finishRender(_ result: Result<any MTLTexture, any Error>, headroom target: CGFloat, generation: Int) {
        rendering = false
        guard generation == renderGeneration else { return }
        switch result {
        case .success(let rendered):
            texture = rendered
            renderedHeadroom = target
            dirty = true
        case .failure(let error):
            renderedHeadroom = target   // the same input would fail again
            // A failed re-render keeps the photo at its last headroom.
            if texture == nil { onError(error.localizedDescription) }
        }
    }

    /// Draws the newest state, one presentation in flight at a time. Without a
    /// texture (no photo, or not rendered yet) the canvas is cleared.
    private func draw() {
        guard let queue, let display, metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable(), let command = queue.makeCommandBuffer() else { return }
        dirty = false
        inFlight = true
        if let texture {
            display.encode(texture, transform: geometry, into: drawable,
                           drawableSize: metalLayer.drawableSize, command: command)
        } else if let encoder = command.makeRenderCommandEncoder(descriptor: EDRDisplayPass.clearPass(drawable)) {
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
        for recognizer in [pinch, pan, doubleTap] as [UIGestureRecognizer] {
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

/// SwiftUI wrapper of `EDRCanvasUIView`.
struct EDRCanvas: UIViewRepresentable {
    var photo: HDRPhoto?
    var onHeadroom: (HeadroomSnapshot) -> Void
    var onError: (String) -> Void

    func makeUIView(context: Context) -> EDRCanvasUIView {
        let view = EDRCanvasUIView(frame: .zero)
        view.onHeadroom = onHeadroom
        view.onError = onError
        view.photo = photo
        return view
    }

    func updateUIView(_ view: EDRCanvasUIView, context: Context) {
        view.onHeadroom = onHeadroom
        view.onError = onError
        if view.photo?.image !== photo?.image { view.photo = photo }
    }
}

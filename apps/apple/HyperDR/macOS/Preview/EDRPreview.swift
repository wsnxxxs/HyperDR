import AppKit
import SwiftUI
import QuartzCore

struct HeadroomSnapshot: Equatable {
    var screen = "等待显示器"
    var current: CGFloat = 1
    var potential: CGFloat = 1
    var reference: CGFloat = 1
}

struct EDRPreview: NSViewRepresentable {
    var original: Bool
    var onHeadroom: (HeadroomSnapshot) -> Void
    var onError: (String) -> Void

    func makeNSView(context: Context) -> EDRMetalView {
        EDRMetalView(onHeadroom: onHeadroom, onError: onError)
    }
    func updateNSView(_ view: EDRMetalView, context: Context) {
        view.original = original
        view.drawPreview()
    }
}

@MainActor final class EDRMetalView: NSView {
    private var renderer: PreviewRenderer?
    private var refreshTimer: Timer?
    private let onHeadroom: (HeadroomSnapshot) -> Void
    private var lastSnapshot: HeadroomSnapshot?
    var original = false

    init(onHeadroom: @escaping (HeadroomSnapshot) -> Void, onError: @escaping (String) -> Void) {
        self.onHeadroom = onHeadroom
        super.init(frame: .zero)
        wantsLayer = true
        do {
            let renderer = try PreviewRenderer()
            self.renderer = renderer
            metalLayer.device = renderer.device
            metalLayer.pixelFormat = .rgba16Float
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.isOpaque = true
        } catch {
            let message = error.localizedDescription
            DispatchQueue.main.async { onError(message) }
        }
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        guard window != nil else { refreshTimer = nil; return }
        // The current headroom changes while EDR content is visible, even when
        // the screen remains the same. Polling also covers display reconfiguration.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDisplay() }
        }
        refreshDisplay()
    }
    override func layout() {
        super.layout()
        updateDrawableSize()
        drawPreview()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshDisplay()
    }
    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
    private func refreshDisplay() {
        updateDrawableSize()
        if let screen = window?.screen {
            let snapshot = HeadroomSnapshot(screen: screen.localizedName,
                current: screen.maximumExtendedDynamicRangeColorComponentValue,
                potential: screen.maximumPotentialExtendedDynamicRangeColorComponentValue,
                reference: screen.maximumReferenceExtendedDynamicRangeColorComponentValue)
            if snapshot != lastSnapshot {
                lastSnapshot = snapshot
                // Publish outside AppKit's layout/update pass.
                DispatchQueue.main.async { [weak self] in self?.onHeadroom(snapshot) }
                print("EDR screen=\(snapshot.screen) current=\(snapshot.current) potential=\(snapshot.potential) reference=\(snapshot.reference)")
            }
        }
        drawPreview()
    }

    func drawPreview() {
        guard window?.isVisible == true else { return }
        renderer?.draw(in: metalLayer, original: original)
    }
}

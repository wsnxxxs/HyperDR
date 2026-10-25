import AppKit
import HyperDRDesign
import SwiftUI

/// The pane laid over the canvas while the white balance eyedropper is
/// active: the eyedropper pointer, the pointer's position and the click for
/// the picker, and Esc to leave. It takes the pointer from the canvas
/// underneath (no pan or hold-for-original while picking) and the keyboard
/// from whatever had it, so Esc arrives here.
struct WhiteBalanceSurface: NSViewRepresentable {
    let picker: WhiteBalancePicker

    func makeNSView(context: Context) -> WhiteBalanceSurfaceView {
        let view = WhiteBalanceSurfaceView()
        view.picker = picker
        return view
    }

    func updateNSView(_ view: WhiteBalanceSurfaceView, context: Context) {
        view.picker = picker
    }
}

@MainActor
final class WhiteBalanceSurfaceView: NSView {
    var picker: WhiteBalancePicker?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The button that started the pick has focus; Esc must come here.
        window?.makeFirstResponder(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.eyedropper)
    }

    override func mouseMoved(with event: NSEvent) {
        picker?.move(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        picker?.move(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        picker?.move(to: nil)
    }

    override func mouseDown(with event: NSEvent) {
        picker?.click(at: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        // Escape.
        if event.keyCode == 53 { picker?.cancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        picker?.cancel()
    }

    /// The eyedropper symbol, white under black so it reads on any photo, its
    /// tip on the pixel that is picked.
    private static let eyedropper: NSCursor = {
        let size = NSSize(width: 28, height: 28)
        let configuration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return .crosshair }
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                color.set()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        let white = tinted(.white), black = tinted(.black)
        let image = NSImage(size: size, flipped: false) { _ in
            let origin = NSPoint(x: 3, y: 3)
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                white.draw(at: NSPoint(x: origin.x + dx, y: origin.y + dy), from: .zero, operation: .sourceOver, fraction: 1)
            }
            black.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // The symbol's tip is its bottom left corner.
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: size.height - 4))
    }()
}

/// The eyedropper's layer over the canvas: the pane that takes the pointer,
/// the loupe, and a line saying what to do. It also ends the mode whenever
/// the photo, the crop pane or the editor's lock changes under it.
struct WhiteBalanceCanvasLayer: View {
    let model: EditorModel

    var body: some View {
        let picker = model.whiteBalance
        ZStack {
            if picker.isActive {
                WhiteBalanceSurface(picker: picker)
                GeometryReader { proxy in
                    WhiteBalanceLoupe(picker: picker, canvas: proxy.size)
                }
                Text("mac.wb.hint")
                    .font(Font.hdr.control)
                    .hdrOverlayChip()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.s3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .hdrAnimation(value: picker.isActive)
        .onChange(of: model.photoSerial) { picker.reset() }
        .onChange(of: model.isCropping) { if model.isCropping { picker.reset() } }
        .onChange(of: model.isEditingLocked) { if model.isEditingLocked { picker.reset() } }
    }
}

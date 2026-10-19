import AppKit
import SwiftUI

/// Hands the hosting `NSWindow` to `onChange` once the view is in one, and
/// again if it moves to another or leaves (nil). For the few things that
/// need the window itself, such as a key monitor scoped to it.
struct WindowReader: NSViewRepresentable {
    var onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Reader()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Reader)?.onChange = onChange
    }

    private final class Reader: NSView {
        var onChange: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange(window)
        }
    }
}

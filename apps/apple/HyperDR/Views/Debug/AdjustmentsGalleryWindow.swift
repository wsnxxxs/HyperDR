#if DEBUG
import AppKit
import SwiftUI
import HyperDRDesign

/// The adjustment controls generated from the recipe's declarations (P7-2a,
/// Developer ▸ Generated Adjustment Controls), on a fake recipe: the pointer
/// and touch styles side by side, for every input domain. Not wired to the
/// editor or to rendering.
@MainActor final class AdjustmentsGalleryWindow {
    static let shared = AdjustmentsGalleryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: AdjustmentsGallery().frame(width: 1060, height: 900)))
            window.title = "Generated Adjustment Controls"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif

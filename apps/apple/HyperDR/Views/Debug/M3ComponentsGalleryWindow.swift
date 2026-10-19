#if DEBUG
import AppKit
import SwiftUI
import HyperDRDesign

/// The export, history and LUT-library components of M3 (Developer ▸
/// Export, History and LUT Components): the format cards, the toolbar
/// button, the progress bars, the status, result and failure cards and the
/// history and LUT rows, to try with the pointer, the keyboard and VoiceOver.
@MainActor final class M3ComponentsGalleryWindow {
    static let shared = M3ComponentsGalleryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: M3ComponentsGallery().frame(width: 1700, height: 900)))
            window.title = "Export, History and LUT Components"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif

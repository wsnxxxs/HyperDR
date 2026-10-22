#if DEBUG
import AppKit
import SwiftUI
import HyperDRDesign

/// The inspector, scope and canvas components of M2 (Developer ▸ Inspector,
/// Scope and Canvas Components): every state of the sliders' Auto and mask
/// marks, the notices, the scope panel, the divider and the canvas legend,
/// to try with the pointer, the keyboard and VoiceOver.
@MainActor final class M2ComponentsGalleryWindow {
    static let shared = M2ComponentsGalleryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: M2ComponentsGallery().frame(width: 1100, height: 820)))
            window.title = "Inspector, Scope and Canvas Components"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
#endif

import AppKit

/// Holding ⌥ marks dead black and clipping on the canvas, as dragging the
/// white or black point does (adjust-tools §3). A local monitor of this
/// window's own events: the key is read from modifier changes, never sent.
@MainActor enum ClippingKeyRule {
    /// Only ⌥ by itself: ⌥⌘, ⌥⇧ and the like belong to commands.
    static func isHeld(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection(.deviceIndependentFlagsMask) == [.option]
    }
}

/// Owns the local monitor of one editor window.
@MainActor final class ClippingKeyMonitor {
    private var monitor: Any?
    private var resignObserver: Any?
    private weak var window: NSWindow?

    func install(window: NSWindow, editor: RecipeEditor) {
        remove()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak editor] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let self, let window = self.window, let editor, event.window === window else { return }
                editor.holdsClippingKey = window.isKeyWindow && ClippingKeyRule.isHeld(event.modifierFlags)
            }
            return event
        }
        // The key is released in another window or app: no event arrives here.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak editor] _ in
            MainActor.assumeIsolated { editor?.holdsClippingKey = false }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }
}

import AppKit

/// ⌘= zooms in (M2-Q). The menu's Zoom In is ⌘+, which needs Shift on most
/// keyboards; ⌘= is what a hand reaches for. A local key monitor, so a menu
/// item for it is not needed and the menu keeps showing one Zoom In.
///
/// It takes the key only when it is surely meant for the photograph: exactly
/// ⌘ and "=" (⇧⌘= is the menu's, ⌥⌘= the system's zoom, ⌃⌘= anyone's), this
/// editor window is key with nothing attached to it, no text is being typed,
/// no enabled menu item claims the key and the canvas can zoom in. In every
/// other case the event goes on untouched.
@MainActor enum ZoomKeyRule {
    /// What the monitor knows of the window at the moment of the event.
    struct Context {
        var isKeyWindow: Bool
        var hasAttachedSheet: Bool
        var hasModalWindow: Bool
        var firstResponder: NSResponder?
        var mainMenu: NSMenu?
    }

    /// Zooms in and returns true when `event` is the zoom-in key for this
    /// window; false when the event should go on.
    static func handle(_ event: NSEvent, context: Context, canvas: CanvasModel) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
              event.charactersIgnoringModifiers == "=",
              context.isKeyWindow, !context.hasAttachedSheet, !context.hasModalWindow,
              !EditorModel.routesUndoToText(context.firstResponder),
              !menuClaims(event, in: context.mainMenu),
              canvas.canZoomIn else { return false }
        canvas.zoomIn()
        return true
    }

    /// Whether an enabled item of `menu` has this key and modifier.
    static func menuClaims(_ event: NSEvent, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        for item in menu.items {
            if item.isEnabled, !item.keyEquivalent.isEmpty, item.keyEquivalent.lowercased() == key,
               item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == flags { return true }
            if let submenu = item.submenu, menuClaims(event, in: submenu) { return true }
        }
        return false
    }
}

/// Owns the local monitor of one editor window.
@MainActor final class ZoomKeyMonitor {
    private var monitor: Any?
    private weak var window: NSWindow?

    func install(window: NSWindow, canvas: CanvasModel) {
        remove()
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak canvas] event in
            // AppKit calls this on the main thread, with an event it owns.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated {
                guard let self, let window = self.window, let canvas, event.window === window else { return false }
                let context = ZoomKeyRule.Context(
                    isKeyWindow: window.isKeyWindow, hasAttachedSheet: window.attachedSheet != nil,
                    hasModalWindow: NSApp.modalWindow != nil, firstResponder: window.firstResponder,
                    mainMenu: NSApp.mainMenu)
                return ZoomKeyRule.handle(event, context: context, canvas: canvas)
            }
            return consumed ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

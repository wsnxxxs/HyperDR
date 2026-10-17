import AppKit

/// Whether the pointer event being handled is a plain primary click or drag.
///
/// SwiftUI's `DragGesture` also follows the secondary button, so without this
/// a right-click or Control-click on a track would move the value before the
/// context menu opened. Drags check every event, so a gesture the menu
/// cuts short leaves nothing behind.
@MainActor var isPrimaryPointerEvent: Bool {
    guard let event = NSApp.currentEvent else { return true }
    switch event.type {
    case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
        return !event.modifierFlags.contains(.control)
    case .rightMouseDown, .rightMouseDragged, .rightMouseUp, .otherMouseDown, .otherMouseDragged, .otherMouseUp:
        return false
    default:
        return true
    }
}

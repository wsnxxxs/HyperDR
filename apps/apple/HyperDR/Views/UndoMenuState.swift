import AppKit
import Observation

/// Lets the Edit menu follow things SwiftUI cannot observe: which view is the
/// key window's first responder, and the undo stacks of the text fields it
/// might be. Anything of the kind bumps `revision`, which the menu items read,
/// so they are evaluated again.
///
/// The editor keeps its own `UndoManager`, not the window's (the model's
/// header says why), so Undo and Redo decide where to go by the first
/// responder: a text field or text view has its own history and gets the
/// command; anything else is the photograph's edit history
/// (`EditorModel.undo(firstResponder:)`).
@MainActor @Observable final class UndoMenuState {
    static let shared = UndoMenuState()

    private(set) var revision = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastResponder: ObjectIdentifier?
    @ObservationIgnored private var isInstalled = false

    func bump() { revision &+= 1 }

    /// Starts listening; once per run.
    func install(center: NotificationCenter = .default) {
        guard !isInstalled else { return }
        isInstalled = true
        // Not `NSUndoManagerCheckpoint`: `canUndo`, `canRedo` and the menu
        // titles post it, so the menu reading them would bump itself forever.
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
            .NSUndoManagerDidCloseUndoGroup,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bump() }
            })
        }
        // The first responder changes without a notification of its own; a
        // window update follows every change, and only a real one bumps.
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = NSApp.keyWindow else { return }
                let current = window.firstResponder.map(ObjectIdentifier.init)
                if current != self.lastResponder {
                    self.lastResponder = current
                    self.bump()
                }
            }
        })
    }
}

/// What Undo and Redo do and say for the current first responder.
@MainActor enum UndoRouting {
    static var firstResponder: NSResponder? { NSApp.keyWindow?.firstResponder }

    /// The history the command goes to: the responder's own for text, else the
    /// editor's (nil without an editor window).
    static func manager(model: EditorModel?, responder: NSResponder?) -> UndoManager? {
        EditorModel.routesUndoToText(responder) ? responder?.undoManager : model?.undoManager
    }

    static func canUndo(model: EditorModel?, responder: NSResponder?) -> Bool {
        if let model { return model.canUndo(firstResponder: responder) }
        return EditorModel.routesUndoToText(responder) && responder?.undoManager?.canUndo == true
    }

    static func canRedo(model: EditorModel?, responder: NSResponder?) -> Bool {
        if let model { return model.canRedo(firstResponder: responder) }
        return EditorModel.routesUndoToText(responder) && responder?.undoManager?.canRedo == true
    }

    static func undo(model: EditorModel?, responder: NSResponder?) {
        if let model { model.undo(firstResponder: responder) } else { responder?.undoManager?.undo() }
    }

    static func redo(model: EditorModel?, responder: NSResponder?) {
        if let model { model.redo(firstResponder: responder) } else { responder?.undoManager?.redo() }
    }

    /// "Undo Change Overall Brightness" from the history the command goes to.
    static func undoTitle(model: EditorModel?, responder: NSResponder?) -> String {
        manager(model: model, responder: responder)?.undoMenuItemTitle ?? UndoManager().undoMenuItemTitle
    }

    static func redoTitle(model: EditorModel?, responder: NSResponder?) -> String {
        manager(model: model, responder: responder)?.redoMenuItemTitle ?? UndoManager().redoMenuItemTitle
    }
}

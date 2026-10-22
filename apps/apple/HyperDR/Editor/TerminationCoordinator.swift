import AppKit

/// The delegate owns the application handshake; the editor owns cancellation
/// and drains preparation, conversion, publication and every save before reply.
@MainActor final class TerminationCoordinator {
    private(set) var isPending = false
    func request(editor: EditorModel, confirmStop: @escaping @MainActor () async -> Bool,
                 reply: @escaping @MainActor (Bool) -> Void) {
        guard !isPending else { return }
        isPending = true
        Task {
            defer { isPending = false }
            guard await editor.needsTerminationConfirmation() else { reply(true); return }
            guard await confirmStop() else { reply(false); return }
            await editor.stopForTermination()
            reply(true)
        }
    }
}
@MainActor final class HyperDRApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var editor: EditorModel?
    let termination = TerminationCoordinator()
    static func terminationAlert(name: String, saving: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = saving ? String(localized: "quit.savingTitle \(name)") : String(localized: "quit.title \(name)")
        alert.informativeText = saving ? String(localized: "quit.savingMessage") : String(localized: "quit.message")
        alert.addButton(withTitle: String(localized: "quit.keep"))
        alert.addButton(withTitle: String(localized: "quit.stop"))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = []
        return alert
    }
    static func continuesOnEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                                  window: NSWindow?, alert: NSAlert) -> Bool {
        keyCode == 53 && modifiers.intersection([.command, .control, .option, .shift]).isEmpty
            && window === alert.window
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let editor else { return .terminateNow }
        termination.request(editor: editor, confirmStop: { [weak editor] in
            let alert = Self.terminationAlert(name: editor?.terminationFileName ?? "", saving: editor?.isSavingForTermination == true)
            // AppKit cannot assign Return and Escape to one default button.
            // This local monitor accepts Escape only in this confirmation's
            // window, performs Continue, and is removed on every exit path.
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated {
                    guard Self.continuesOnEscape(keyCode: event.keyCode, modifiers: event.modifierFlags,
                        window: event.window, alert: alert) else { return false }
                    alert.buttons[0].performClick(nil)
                    return true
                }
                return handled ? nil : event
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            let response: NSApplication.ModalResponse
            if let window = sender.keyWindow { response = await alert.beginSheetModal(for: window) }
            else { response = alert.runModal() }
            return response == .alertSecondButtonReturn
        }, reply: { sender.reply(toApplicationShouldTerminate: $0) })
        return .terminateLater
    }
}

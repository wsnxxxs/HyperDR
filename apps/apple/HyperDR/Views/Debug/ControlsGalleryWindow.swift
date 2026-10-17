#if DEBUG
import AppKit
import SwiftUI
import HyperDRDesign

/// The HyperDRDesign inspector controls in a window of their own (Developer ▸
/// Inspector Controls), for trying them with the pointer, the keyboard and
/// VoiceOver before M2 puts them in the inspector. `-HDRControlsGallery show`
/// opens it at launch.
@MainActor final class ControlsGalleryWindow {
    static let shared = ControlsGalleryWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: InspectorControlsGallery().frame(height: 820)))
            window.title = "Inspector Controls"
            window.styleMask.remove(.resizable)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func showIfRequested() {
        guard UserDefaults.standard.string(forKey: "HDRControlsGallery") == "show" else { return }
        shared.show()
        shared.listenForPointerScripts()
    }

    // MARK: Pointer scripts

    /// Lets a test drive the pointer in this window only: a distributed
    /// notification `HDRControlsGalleryPointer` whose object is a script such
    /// as "drag 1450 201 1522 201; dclick 1530 201" (also "click", "rclick"), in screen points with a
    /// top-left origin (what the accessibility API reports). The events are
    /// posted to this app's own queue for this window, never system-wide.
    private func listenForPointerScripts() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("HDRControlsGalleryPointer"), object: nil, queue: .main) { note in
            guard let script = note.object as? String else { return }
            MainActor.assumeIsolated { ControlsGalleryWindow.shared.run(script) }
        }
    }

    private func run(_ script: String) {
        guard let window, let screen = NSScreen.screens.first else { return }
        let height = screen.frame.height
        let number = window.windowNumber
        // Screen (top-left origin) to window coordinates.
        let local = { (x: Double, y: Double) in
            CGPoint(x: x - window.frame.minX, y: height - y - window.frame.minY)
        }
        var steps: [(NSEvent.EventType, CGPoint, Int)] = []
        for command in script.split(separator: ";") {
            let words = command.split(separator: " ")
            guard let name = words.first else { continue }
            let n = words.dropFirst().compactMap { Double($0) }
            switch name {
            case "click" where n.count == 2, "dclick" where n.count == 2:
                let p = local(n[0], n[1])
                steps += [(.leftMouseDown, p, 1), (.leftMouseUp, p, 1)]
                if name == "dclick" { steps += [(.leftMouseDown, p, 2), (.leftMouseUp, p, 2)] }
            case "rclick" where n.count == 2:
                let p = local(n[0], n[1])
                steps += [(.rightMouseDown, p, 1), (.rightMouseUp, p, 1)]
            case "drag" where n.count == 4:
                let a = local(n[0], n[1]), b = local(n[2], n[3])
                steps.append((.leftMouseDown, a, 1))
                for i in 1...20 {
                    let t = Double(i) / 20
                    steps.append((.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), 1))
                }
                steps.append((.leftMouseUp, b, 1))
            default:
                break
            }
        }
        PointerPoster().post(steps, window: number)
    }
}

/// Posts events from a background thread, spaced like a real pointer.
nonisolated private struct PointerPoster: @unchecked Sendable {
    private typealias PostEvent = @convention(c) (AnyObject, Selector, NSEvent, Bool) -> Void
    private let app: AnyObject
    private let post: PostEvent
    private let selector = NSSelectorFromString("postEvent:atStart:")

    @MainActor init() {
        app = NSApp
        // -[NSApplication postEvent:atStart:] may be called from any thread.
        post = unsafeBitCast(class_getMethodImplementation(NSApplication.self, selector), to: PostEvent.self)
    }

    /// Each event is made when it is posted, so its timestamp is real: click
    /// counting and gesture timing depend on it.
    func post(_ steps: [(NSEvent.EventType, CGPoint, Int)], window: Int) {
        Thread.detachNewThread { [self] in
            // Real mouse events are numbered, a press and its release alike.
            var number = Int(ProcessInfo.processInfo.systemUptime * 1000) % 1_000_000
            for (type, point, clicks) in steps {
                if type == .leftMouseDown || type == .rightMouseDown { number += 1 }
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window, context: nil, eventNumber: number, clickCount: clicks,
                    pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) else { continue }
                post(app, selector, event, false)
                Thread.sleep(forTimeInterval: 0.012)
            }
        }
    }
}
#endif

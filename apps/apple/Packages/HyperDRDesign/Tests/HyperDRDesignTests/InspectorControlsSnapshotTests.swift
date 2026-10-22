import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

/// Writes the inspector controls gallery in light, dark and Increase
/// Contrast to $HDR_SNAPSHOT_DIR, for the design record in docs/design/.
/// Skipped when the variable is not set.
///
/// Rendered through an off-screen window rather than `ImageRenderer`, which
/// cannot draw the AppKit-backed value fields.
@MainActor @Test func inspectorControlsSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let variants: [(String, ColorScheme, ColorSchemeContrast)] = [
        ("light", .light, .standard), ("dark", .dark, .standard),
        ("light-contrast", .light, .increased), ("dark-contrast", .dark, .increased),
    ]
    for (name, scheme, contrast) in variants {
        let view = InspectorControlsGallery().column
            .frame(width: Layout.inspectorWidth)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
            .environment(\._colorSchemeContrast, contrast)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("inspector-controls-\(name).png"))
    }
}

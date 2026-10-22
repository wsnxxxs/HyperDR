import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

private func hex(_ name: String, _ appearance: NSAppearance.Name) -> String? {
    guard let color = NSColor(named: name, bundle: .module) else { return nil }
    var result: String?
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        result = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                        Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
    return result
}

@Test func everyTokenIsInTheCatalogue() {
    for token in Palette.tokens {
        #expect(NSColor(named: token.name, bundle: .module) != nil, "\(token.name)")
    }
    #expect(Set(Palette.tokens.map(\.name)).count == Palette.tokens.count)
}

@Test func anchorValuesFollowTheAppearance() {
    #expect(hex("accent", .aqua) == "#0071E3")
    #expect(hex("accent", .darkAqua) == "#8BA8FF")
    #expect(hex("accentFill", .darkAqua) == "#3A6DDC")
    #expect(hex("surfacePanel", .aqua) == "#FBFBFC")
    #expect(hex("surfacePanel", .darkAqua) == "#1E1F23")
    // Dark in both appearances: the photograph decides nothing.
    #expect(hex("previewBackdrop", .aqua) == hex("previewBackdrop", .darkAqua))
}

@Test func inspectorNarrowsWithTheWindow() {
    #expect(Layout.inspectorWidth(forWindowWidth: 1440) == 342)
    #expect(Layout.inspectorWidth(forWindowWidth: 1000) == 320)
    #expect(Layout.inspectorWidth(forWindowWidth: 800) == 300)
}

/// Writes the gallery in both appearances to $HDR_SNAPSHOT_DIR, for the design
/// record in docs/design/. Skipped when the variable is not set.
@MainActor @Test func gallerySnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
        let renderer = ImageRenderer(content: TokenGallery().sheet.frame(width: 1180).environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let data = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tokens-\(name).png"))
    }
}

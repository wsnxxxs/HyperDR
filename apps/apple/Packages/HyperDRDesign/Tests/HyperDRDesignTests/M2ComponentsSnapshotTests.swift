import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

/// Renders `view` off screen as a bitmap, through an unshown borderless
/// window rather than `ImageRenderer`, which cannot draw the AppKit-backed
/// value fields.
@MainActor func snapshot(_ view: some View, width: CGFloat? = nil, scheme: ColorScheme = .light,
                         contrast: ColorSchemeContrast = .standard, locale: String = "en") throws -> NSBitmapImageRep {
    var sized = AnyView(view)
    if let width { sized = AnyView(view.frame(width: width)) }
    let root = sized
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, scheme)
        .environment(\._colorSchemeContrast, contrast)
        .environment(\.locale, Locale(identifier: locale))
    let host = NSHostingView(rootView: root)
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
    return bitmap
}

private func png(_ bitmap: NSBitmapImageRep) throws -> Data {
    try #require(bitmap.representation(using: .png, properties: [:]))
}

/// The number of distinct pixel values sampled across the bitmap: a blank
/// or failed render has one or two.
private func distinctColours(_ bitmap: NSBitmapImageRep) -> Int {
    var seen = Set<UInt32>()
    let stepX = max(bitmap.pixelsWide / 97, 1), stepY = max(bitmap.pixelsHigh / 89, 1)
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            seen.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
        }
    }
    return seen.count
}

private let variants: [(String, ColorScheme, ColorSchemeContrast, String)] = [
    ("light", .light, .standard, "en"), ("dark", .dark, .standard, "en"),
    ("light-contrast", .light, .increased, "en"), ("dark-contrast", .dark, .increased, "en"),
    ("light-zh-Hans", .light, .standard, "zh-Hans"), ("dark-zh-Hans", .dark, .standard, "zh-Hans"),
]

/// Renders the M2 components gallery in light, dark, Increase Contrast and
/// Chinese, and checks each render has something on it. With
/// $HDR_SNAPSHOT_DIR set, also writes `m2-components-<variant>.png` (the
/// inspector column) and `m2-components-canvas-<variant>.png` (the canvas
/// column) there, for the design record in docs/design/.
@MainActor @Test func m2ComponentsSnapshots() throws {
    let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"]
    for (name, scheme, contrast, locale) in variants {
        let inspector = try snapshot(M2ComponentsGallery().inspectorColumn, width: Layout.inspectorWidth,
                                     scheme: scheme, contrast: contrast, locale: locale)
        let canvas = try snapshot(M2ComponentsGallery().canvasColumn, scheme: scheme, contrast: contrast, locale: locale)
        #expect(distinctColours(inspector) > 40, "inspector column blank: \(name)")
        #expect(distinctColours(canvas) > 40, "canvas column blank: \(name)")
        if let directory {
            try png(inspector).write(to: URL(fileURLWithPath: directory).appendingPathComponent("m2-components-\(name).png"))
            try png(canvas).write(to: URL(fileURLWithPath: directory).appendingPathComponent("m2-components-canvas-\(name).png"))
        }
    }
}

/// Light and dark, English and Chinese are four different pictures.
@MainActor @Test func m2SnapshotsFollowAppearanceAndLanguage() throws {
    func data(_ scheme: ColorScheme, _ locale: String) throws -> Data {
        try png(snapshot(ScopePanel(kind: .constant(.histogram), channels: .constant(.luma), isExpanded: .constant(true),
                                    highlightZebra: .constant(true), shadowZebra: .constant(false),
                                    content: .data(M2Fixtures.data), ceilingStops: 2.5),
                         width: Layout.inspectorWidth, scheme: scheme, locale: locale))
    }
    let pictures = try [data(.light, "en"), data(.dark, "en"), data(.light, "zh-Hans"), data(.dark, "zh-Hans")]
    #expect(Set(pictures).count == 4)
}

import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

private let box = CGSize(width: 96, height: 64)

@Test func aPictureOfTheBoxProportionFillsIt() {
    for ratio in [1.5, 1.5 * 1.009, 1.5 / 1.009] {
        let fit = ThumbnailFit(aspectRatio: ratio, in: box)
        #expect(fit.fills, "\(ratio) is within 1 % of the box")
        #expect(fit.size == box)
    }
}

@Test func otherProportionsAreFittedWholeAndGetAnEdgeLine() {
    let wide = ThumbnailFit(aspectRatio: 4, in: box)
    #expect(!wide.fills)
    #expect(wide.size == CGSize(width: 96, height: 24))
    let tall = ThumbnailFit(aspectRatio: 9.0 / 16, in: box)
    #expect(!tall.fills)
    #expect(tall.size.height == 64 && abs(tall.size.width - 36) < 0.001)
    // Just past the tolerance still counts as not filling.
    #expect(!ThumbnailFit(aspectRatio: 1.5 * 1.02, in: box).fills)
    for ratio in [4.0 / 3, 16.0 / 9, 1, 2.0 / 3, 10, 0.1] {
        let fit = ThumbnailFit(aspectRatio: ratio, in: box)
        #expect(fit.size.width <= box.width + 0.001 && fit.size.height <= box.height + 0.001, "\(ratio) stays inside the box")
        #expect(abs(fit.size.width / fit.size.height - ratio) < 0.001, "\(ratio) is not distorted")
    }
}

@Test func aMeaninglessProportionFillsTheBox() {
    #expect(ThumbnailFit(aspectRatio: 0, in: box).fills)
    #expect(ThumbnailFit(aspectRatio: 2, in: .zero).fills)
}

@MainActor private func thumbnailBitmap(_ content: ThumbnailContent, scheme: ColorScheme = .light, contrast: ColorSchemeContrast = .standard,
                             locale: String = "en", spinnerDelay: Duration? = nil) throws -> NSBitmapImageRep {
    var thumbnail = Thumbnail(content, width: 96, height: 64)
    if let spinnerDelay { thumbnail = thumbnail.spinnerDelay(spinnerDelay) }
    return try snapshot(thumbnail.padding(8), scheme: scheme, contrast: contrast, locale: locale)
}

private func pixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) throws -> NSColor {
    let scale = CGFloat(bitmap.pixelsWide) / 112
    return try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
}

private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
}

private let schemes: [(ColorScheme, ColorSchemeContrast, String)] = [
    (.light, .standard, "en"), (.dark, .standard, "en"), (.light, .increased, "en"), (.dark, .increased, "en"),
    (.light, .standard, "zh-Hans"), (.dark, .standard, "zh-Hans"),
]

/// Ready, loading and none are three pictures in every appearance and language.
@MainActor @Test func theThreeStatesLookDifferentEverywhere() throws {
    for (scheme, contrast, locale) in schemes {
        func data(_ content: ThumbnailContent) throws -> Data {
            try #require(thumbnailBitmap(content, scheme: scheme, contrast: contrast, locale: locale)
                .representation(using: .png, properties: [:]))
        }
        let states = try [data(Thumbnails.photo()), data(.loading()), data(.unavailable)]
        #expect(Set(states).count == states.count, "\(scheme) \(contrast) \(locale)")
    }
}

/// The spinner waits for its delay and a wait that is cancelled (the picture
/// arrived first) never shows it. A bitmap of the view cannot draw the AppKit
/// progress indicator, so the timing is tested on the gate the view uses.
@MainActor @Test func theSpinnerShowsOnlyAfterTheDelay() async {
    let quick = SpinnerGate()
    #expect(!quick.isShown)
    await quick.wait(.zero)
    #expect(quick.isShown)

    let slow = SpinnerGate()
    let waiting = Task { await slow.wait(.milliseconds(400)) }
    try? await Task.sleep(for: .milliseconds(100))
    #expect(!slow.isShown, "still empty before the delay")
    await waiting.value
    #expect(slow.isShown, "a spinner after it")

    let cancelled = SpinnerGate()
    let early = Task { await cancelled.wait(.seconds(600)) }
    early.cancel()
    await early.value
    #expect(!cancelled.isShown, "the picture arrived first: no spinner")
}

/// The spinner in a real mounted view. A bitmap cannot draw the AppKit
/// progress indicator, so count the indicators in the hosted hierarchy.
@MainActor private func spinners(in host: NSView) -> Int {
    host.layoutSubtreeIfNeeded()
    func count(_ view: NSView) -> Int { (view is NSProgressIndicator ? 1 : 0) + view.subviews.map(count).reduce(0, +) }
    return count(host)
}

@MainActor private func mount(_ content: ThumbnailContent, delay: Duration) -> (NSHostingView<Thumbnail>, NSWindow) {
    let host = NSHostingView(rootView: Thumbnail(content, width: 172, height: 115).spinnerDelay(delay))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 172, height: 115), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 172, height: 115)
    return (host, window)
}

/// A mounted summary box shows no spinner before the delay and one after it;
/// a box that is not the summary's, or one removed first, never gets one.
@MainActor @Test func aMountedBoxShowsItsSpinnerOnlyAfterTheDelay() async throws {
    let (host, window) = mount(.loading(showsSpinner: true), delay: .milliseconds(500))
    try await Task.sleep(for: .milliseconds(150))
    #expect(spinners(in: host) == 0, "not before the delay")
    try await Task.sleep(for: .milliseconds(700))
    #expect(spinners(in: host) == 1, "after it")
    withExtendedLifetime(window) {}

    let (plain, plainWindow) = mount(.loading(), delay: .zero)
    try await Task.sleep(for: .milliseconds(300))
    #expect(spinners(in: plain) == 0, "only the summary spins")
    withExtendedLifetime(plainWindow) {}

    let (gone, goneWindow) = mount(.loading(showsSpinner: true), delay: .milliseconds(300))
    goneWindow.contentView = nil
    try await Task.sleep(for: .milliseconds(600))
    #expect(spinners(in: gone) == 0, "removed before the delay: no spinner")
    withExtendedLifetime(goneWindow) {}
}

/// The loading box has the sunken surface and an outline and no icon: the
/// centre is the box colour.
@MainActor @Test func aLoadingBoxIsEmptyAndAnUnavailableOneHasItsIcon() throws {
    let loading = try thumbnailBitmap(.loading())
    let none = try thumbnailBitmap(.unavailable)
    let edge = try pixel(loading, x: 20, y: 20)
    #expect(distance(try pixel(loading, x: 56, y: 40), edge) < 0.01, "no icon while loading")
    let size = CGFloat(none.pixelsWide) / 112
    var differs = false
    for dy in stride(from: 28.0, to: 52.0, by: 1.0) {
        for dx in stride(from: 44.0, to: 68.0, by: 1.0) where distance(try pixel(none, x: dx, y: dy), edge) > 0.05 { differs = true }
    }
    #expect(size > 0 && differs, "the placeholder icon is drawn")
}

/// A white picture on the light box and a black one on the dark box are only
/// visible by their edge line: it is there when the picture does not fill the
/// box, and not when it does.
@MainActor @Test func theEdgeLineMarksAPictureThatDoesNotFillTheBox() throws {
    for (scheme, color) in [(ColorScheme.light, Color.white), (.dark, .black)] {
        for contrast in [ColorSchemeContrast.standard, .increased] {
            let wide = try thumbnailBitmap(Thumbnails.solid(color, aspectRatio: 4), scheme: scheme, contrast: contrast)
            // A 4:1 picture in 96 × 64 occupies rows 20…44 of the box (8 pt padding).
            let edge = try pixel(wide, x: 56, y: 28.2), inside = try pixel(wide, x: 56, y: 40)
            #expect(distance(edge, inside) > 0.02, "edge line on a same-colour box: \(scheme) \(contrast)")
            let full = try thumbnailBitmap(Thumbnails.solid(color, aspectRatio: 1.5), scheme: scheme, contrast: contrast)
            #expect(distance(try pixel(full, x: 56, y: 12.2), try pixel(full, x: 56, y: 40)) < 0.02, "no inner line when it fills")
        }
    }
}

/// The picture is not dimmed or tinted by the appearance, in light or dark,
/// or with Increase Contrast.
@MainActor @Test func thePictureDoesNotChangeWithTheAppearance() throws {
    let reference = try pixel(thumbnailBitmap(Thumbnails.photo()), x: 56, y: 40)
    for (scheme, contrast, locale) in schemes {
        let other = try pixel(thumbnailBitmap(Thumbnails.photo(), scheme: scheme, contrast: contrast, locale: locale), x: 56, y: 40)
        #expect(distance(reference, other) < 0.02, "\(scheme) \(contrast)")
    }
}

/// The whole picture shows: a panorama is shorter than the box, with the
/// sunken surface above and below.
@MainActor @Test func aPanoramaIsLetterboxedNotCropped() throws {
    let bitmap = try thumbnailBitmap(Thumbnails.photo(aspectRatio: 4))
    let above = try pixel(bitmap, x: 56, y: 16), middle = try pixel(bitmap, x: 56, y: 40)
    let surface = try pixel(thumbnailBitmap(.loading()), x: 56, y: 16)
    #expect(distance(above, surface) < 0.01, "the band above the panorama is the box colour")
    #expect(distance(middle, surface) > 0.05, "the picture is in the middle")
}

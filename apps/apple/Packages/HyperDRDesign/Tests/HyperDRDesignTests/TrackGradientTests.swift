import AppKit
import SwiftUI
import Testing
@testable import HyperDRDesign

@Test func mixerHueTrackRunsBetweenTheNeighbouringColours() {
    // Red's neighbours are magenta (before it) and orange (after it): the
    // track passes through red once, in the middle.
    let stops = TrackGradient.shift(of: .red)
    #expect(stops.count == 9)
    let turns = MixerBand.allCases.map(\.turns)
    #expect(turns.first == 0)
    // From magenta (0.88) to red (0) is the short way round, through 1.
    #expect(MixerBand.magenta.turns > 0.5)
}

@Test func saturationTrackStartsAtGrey() {
    let stops = TrackGradient.saturation(toward: MixerBand.blue.swatch)
    #expect(stops.count == 2)
    #expect(stops[0] == TrackGradient.grey)
}

@Test func ringCoversTheWholeCircle() {
    #expect(TrackGradient.ring().count == 13)
}

/// Writes the colour sections with their gradient tracks, in light and dark,
/// to $HDR_SNAPSHOT_DIR. Skipped when the variable is not set.
@MainActor @Test func colourSectionGradientSnapshots() throws {
    guard let directory = ProcessInfo.processInfo.environment["HDR_SNAPSHOT_DIR"] else { return }
    let pieces: [(String, AnyView)] = [
        ("mixer-attribute", AnyView(ColorSectionsGallery(arrangement: 0))),
        ("mixer-band", AnyView(ColorSectionsGallery(arrangement: 1))),
        ("grading", AnyView(ColorSectionsGallery(showsGrading: true))),
        ("mixer-touch", AnyView(ColorSectionsGallery(style: .touch, arrangement: 1))),
    ]
    for (name, piece) in pieces {
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = piece.frame(width: 340).fixedSize(horizontal: false, vertical: true)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
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
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("gradient-\(name)-\(scheme).png"))
        }
    }
}

import AppKit
import HyperDRRecipe
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

@Test func wheelSwatchesAreTheShadersColours() {
    // Hue is the recipe's own angle, so the wheel's red end and its opposite differ,
    // and zero saturation is the neutral middle.
    #expect(GradingWheelMath.ring(.dark).count == 25)
    #expect(GradingWheelMath.colour(hue: 40, saturation: 0) == GradingWheelMath.neutral)
    #expect(GradingWheelMath.colour(hue: 30, saturation: 80) != GradingWheelMath.colour(hue: 210, saturation: 80))
    let red = GradingColor.displayRGB(hue: 30, saturation: 100)
    #expect(red.x > red.z)
}

@Test func discAngleIsTheRecipesHue() {
    // The disc is drawn with the hue as its angle, clockwise from the right as
    // the puck is placed: the colour there has that OKLab hue, at both lightnesses.
    for lightness in [GradingDisc.lightness(.light), GradingDisc.lightness(.dark)] {
        for hue in stride(from: 0.0, to: 360, by: 30) {
            let encoded = GradingDisc.rgb(hue: hue, saturation: 100, lightness: lightness)
            func decode(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let lab = GradingDisc.oklab(linear: SIMD3(decode(encoded.x), decode(encoded.y), decode(encoded.z)))
            var angle = atan2(lab.z, lab.y) * 180 / .pi
            if angle < 0 { angle += 360 }
            let error = abs(((angle - hue) + 540).truncatingRemainder(dividingBy: 360) - 180)
            #expect(error < 1, "hue \(hue) drawn at \(angle)")
            #expect(abs(lab.x - lightness) < 0.01)
        }
    }
    // The puck for a hue sits at that angle: 90° is straight down, as y grows downwards.
    let puck = GradingWheelMath.point(hue: 90, saturation: 100, center: .zero, radius: 10)
    #expect(abs(puck.x) < 1e-9 && abs(puck.y - 10) < 1e-9)
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

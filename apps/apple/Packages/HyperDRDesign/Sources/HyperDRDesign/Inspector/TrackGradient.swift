import SwiftUI

/// Colours a slider's track can show for what it moves (adjust-tools §6): a hue
/// control runs along the colour circle, a saturation control from grey to
/// the colour it makes more of. Like the zone swatches they stand for data,
/// not for the interface.
enum TrackGradient {
    /// The colour at an angle of the circle in turns; any number wraps.
    static func colour(turns: Double, saturation: Double = 0.72, brightness: Double = 0.95) -> Color {
        let wrapped = turns - turns.rounded(.down)
        return Color(hue: wrapped, saturation: saturation, brightness: brightness)
    }

    /// The grey a saturation track starts from.
    static let grey = Color(white: 0.55)

    /// The whole circle, red to red.
    static func ring(steps: Int = 12) -> [Color] {
        (0...steps).map { colour(turns: Double($0) / Double(steps), saturation: 0.85) }
    }

    /// Stops from one angle to another along the shorter way round.
    static func sweep(from start: Double, to end: Double, steps: Int = 4) -> [Color] {
        var delta = (end - start).truncatingRemainder(dividingBy: 1)
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        return (0...steps).map { colour(turns: start + delta * Double($0) / Double(steps)) }
    }

    /// A mixer zone's hue track: the neighbouring colour on the left, the zone's
    /// own in the middle, the next on the right, so the track shows where
    /// moving the hue takes the colour.
    static func shift(of band: MixerBand) -> [Color] {
        let all = MixerBand.allCases
        let index = all.firstIndex(of: band) ?? 0
        let before = all[(index + all.count - 1) % all.count].turns
        let after = all[(index + 1) % all.count].turns
        return sweep(from: before, to: band.turns) + sweep(from: band.turns, to: after).dropFirst()
    }

    /// Grey to the colour.
    static func saturation(toward colour: Color) -> [Color] { [grey, colour] }
}

extension EnvironmentValues {
    /// Colours the track of the slider below shows instead of its plain line.
    @Entry var sliderTrackGradient: [Color]?
}

/// A track of colour: the line a gradient slider's thumb moves along.
struct GradientTrack: View {
    let stops: [Color]
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
            .frame(height: height)
    }
}

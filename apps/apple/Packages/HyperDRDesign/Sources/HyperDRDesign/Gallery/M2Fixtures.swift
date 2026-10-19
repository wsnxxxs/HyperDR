import SwiftUI

/// Synthetic scope data and a drawn "photograph" for the M2 gallery and its
/// snapshots: only for looking at layout and colour, not measurements.
enum M2Fixtures {
    /// Bins of a histogram: a sum of bumps given as (centre, width, weight)
    /// on the ruler's 0…1 axis.
    static func bins(_ bumps: [(Double, Double, Double)], count: Int = 256, floor: Double = 0) -> [UInt32] {
        (0..<count).map { index in
            let x = (Double(index) + 0.5) / Double(count)
            let value = bumps.reduce(floor) { sum, bump in
                let z = (x - bump.0) / bump.1
                return sum + bump.2 * exp(-0.5 * z * z)
            }
            return UInt32(max(0, value))
        }
    }

    static let original = HistogramCounts(
        luma: bins([(0.13, 0.05, 9000), (0.28, 0.07, 14000), (0.45, 0.06, 7000), (0.58, 0.05, 6000), (0.66, 0.02, 3500)]),
        red: bins([(0.16, 0.06, 7000), (0.32, 0.07, 12000), (0.5, 0.06, 6000), (0.62, 0.04, 4500)]),
        green: bins([(0.12, 0.05, 8000), (0.27, 0.07, 13000), (0.46, 0.06, 6500), (0.6, 0.05, 5000)]),
        blue: bins([(0.1, 0.05, 9500), (0.25, 0.08, 14000), (0.42, 0.06, 7500), (0.55, 0.05, 5500)]))

    static let edited = HistogramCounts(
        luma: bins([(0.1, 0.04, 6000), (0.3, 0.06, 13000), (0.47, 0.05, 9000), (0.62, 0.06, 5000),
                    (0.76, 0.05, 2200), (0.9, 0.012, 3800)]),
        red: bins([(0.12, 0.05, 5500), (0.34, 0.06, 11500), (0.52, 0.05, 7000), (0.7, 0.05, 3500), (0.86, 0.01, 3000)]),
        green: bins([(0.09, 0.04, 6500), (0.3, 0.06, 12500), (0.5, 0.05, 7500), (0.68, 0.05, 3000), (0.92, 0.012, 2600)]),
        blue: bins([(0.08, 0.04, 7000), (0.27, 0.07, 13500), (0.44, 0.05, 8000), (0.6, 0.05, 3200), (0.96, 0.01, 2800)]))

    /// A waveform: a wavy mid-tone trace across, a dark band at the foot of
    /// the left, and a hot spot of highlights above SDR white.
    static let waveform: WaveformCounts = {
        let columns = 160, rows = 256
        var counts = [UInt32](repeating: 0, count: columns * rows)
        func add(_ x: Int, _ position: Double, _ weight: Double, spread: Double) {
            for row in 0..<rows {
                let y = (Double(row) + 0.5) / Double(rows)
                let z = (y - position) / spread
                counts[row * columns + x] += UInt32(weight * exp(-0.5 * z * z))
            }
        }
        for x in 0..<columns {
            let t = Double(x) / Double(columns)
            add(x, 0.52 + 0.06 * sin(t * 14), 900, spread: 0.035)
            add(x, 0.36 + 0.04 * sin(t * 9 + 1), 500, spread: 0.05)
            if x < columns / 3 { add(x, 0.08, 700, spread: 0.03) }
            if x > columns * 11 / 20, x < columns * 13 / 20 { add(x, 0.87, 600, spread: 0.02) }
        }
        return WaveformCounts(columns: columns, rows: rows, counts: counts)
    }()

    static let data = ScopeData(original: original, current: edited, waveform: waveform)
}

/// A drawn landscape standing in for a photograph.
struct FixturePhoto: View {
    var body: some View {
        Canvas { context, size in
            let sky = Gradient(colors: [Color(red: 0.26, green: 0.36, blue: 0.62), Color(red: 0.74, green: 0.58, blue: 0.56),
                                        Color(red: 0.93, green: 0.72, blue: 0.5)])
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height * 0.62)))
            let sun = CGRect(x: size.width * 0.62 - 30, y: size.height * 0.3 - 30, width: 60, height: 60)
            context.fill(Path(ellipseIn: sun.insetBy(dx: -40, dy: -40)),
                         with: .radialGradient(Gradient(colors: [.white.opacity(0.7), .white.opacity(0)]),
                                               center: CGPoint(x: sun.midX, y: sun.midY), startRadius: 0, endRadius: 80))
            context.fill(Path(ellipseIn: sun), with: .color(Color(red: 1, green: 0.97, blue: 0.88)))
            var mountains = Path()
            mountains.move(to: CGPoint(x: 0, y: size.height * 0.62))
            for (x, y) in [(0.08, 0.5), (0.16, 0.57), (0.26, 0.42), (0.36, 0.56), (0.47, 0.47), (0.58, 0.58),
                           (0.7, 0.44), (0.82, 0.56), (0.92, 0.48), (1.0, 0.58)] {
                mountains.addLine(to: CGPoint(x: size.width * x, y: size.height * y))
            }
            mountains.addLine(to: CGPoint(x: size.width, y: size.height * 0.62))
            mountains.closeSubpath()
            context.fill(mountains, with: .color(Color(red: 0.4, green: 0.34, blue: 0.4)))
            let water = Gradient(colors: [Color(red: 0.62, green: 0.5, blue: 0.46), Color(red: 0.12, green: 0.11, blue: 0.16)])
            context.fill(Path(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38)),
                         with: .linearGradient(water, startPoint: CGPoint(x: 0, y: size.height * 0.62),
                                               endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}

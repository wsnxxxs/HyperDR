import SwiftUI

/// The ruler of the scopes: a 4 pt colour band from black through SDR white
/// to the extended range, with the marks and labels of `ScopeScale.ticks`
/// at their true positions. The histogram lays it out across, the waveform
/// up the side.
struct ScopeAxisRamp: View {
    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    /// Along the ruler, in points.
    let length: CGFloat

    /// Height of a horizontal ruler: band, gap, marks, gap, labels.
    static let horizontalHeight: CGFloat = 24
    /// Width of a vertical ruler: label column, marks, gap, band.
    static let verticalWidth: CGFloat = 56
    static let labelColumn: CGFloat = 46
    private static let band: CGFloat = 4
    private static let labelHeight: CGFloat = 12
    private static let longMark: CGFloat = 4
    private static let shortMark: CGFloat = 3

    var body: some View {
        switch orientation {
        case .horizontal: horizontal
        case .vertical: vertical
        }
    }

    private var ramp: [Gradient.Stop] {
        let p = Color.hdr
        return [.init(color: p.histogramRampShadow, location: 0),
                .init(color: p.histogramRampWhite, location: ScopeScale.sdrShare),
                .init(color: p.histogramRampHDR, location: ScopeScale.sdrShare),
                .init(color: p.histogramRampPeak, location: 1)]
    }

    private var horizontal: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(LinearGradient(stops: ramp, startPoint: .leading, endPoint: .trailing))
                .frame(width: length, height: Self.band)
            Canvas { context, size in
                for tick in ScopeScale.ticks {
                    let x = (tick.position * size.width).clamped(to: 0.5...(size.width - 0.5))
                    var mark = Path()
                    mark.move(to: CGPoint(x: x, y: 0))
                    mark.addLine(to: CGPoint(x: x, y: tick.isMajor ? Self.longMark : Self.shortMark))
                    context.stroke(mark, with: .color(Color.hdr.inkMuted.opacity(tick.isMajor ? 1 : 0.45)), lineWidth: 1)
                }
            }
            .frame(width: length, height: Self.longMark)
            .padding(.top, 2)
            ZStack(alignment: .topLeading) {
                ForEach(ScopeScale.ticks.filter { $0.label != nil }, id: \.position) { tick in
                    label(tick)
                        .alignmentGuide(.leading) { d in
                            let anchor: CGFloat = tick.anchor == .leading ? 0 : tick.anchor == .center ? 0.5 : 1
                            return d.width * anchor - CGFloat(tick.position) * length
                        }
                }
            }
            .frame(width: length, height: Self.labelHeight, alignment: .topLeading)
            .padding(.top, 2)
        }
        .frame(width: length, height: Self.horizontalHeight, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private var vertical: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                ForEach(ScopeScale.ticks.filter { $0.label != nil }, id: \.position) { tick in
                    label(tick)
                        .alignmentGuide(.top) { d in
                            // The first label stands on the bottom edge, the last hangs from the top.
                            let anchor: CGFloat = tick.anchor == .leading ? 1 : tick.anchor == .center ? 0.5 : 0
                            return d.height * anchor - (1 - CGFloat(tick.position)) * length
                        }
                }
            }
            .frame(width: Self.labelColumn, height: length, alignment: .topTrailing)
            Canvas { context, size in
                for tick in ScopeScale.ticks {
                    let y = ((1 - tick.position) * size.height).clamped(to: 0.5...(size.height - 0.5))
                    var mark = Path()
                    mark.move(to: CGPoint(x: size.width, y: y))
                    mark.addLine(to: CGPoint(x: size.width - (tick.isMajor ? Self.longMark : Self.shortMark), y: y))
                    context.stroke(mark, with: .color(Color.hdr.inkMuted.opacity(tick.isMajor ? 1 : 0.45)), lineWidth: 1)
                }
            }
            .frame(width: Self.longMark, height: length)
            Capsule()
                .fill(LinearGradient(stops: ramp, startPoint: .bottom, endPoint: .top))
                .frame(width: Self.band, height: length)
                .padding(.leading, 2)
        }
        .frame(width: Self.verticalWidth, height: length, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func label(_ tick: ScopeScale.Tick) -> some View {
        Text(verbatim: tick.label ?? "")
            .font(.hdr.mono(10))
            .foregroundStyle(Color.hdr.inkMuted)
            .fixedSize()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

import SwiftUI

/// The histogram's plot: a sunken well with the HDR region tinted, the
/// ruler's marks and quarter lines as a grid, the original frame as a
/// filled, dashed shape behind, the edited one as a line in front, and the
/// export limit as a dashed red line.
struct HistogramPlot: View {
    let original: HistogramCounts?
    let current: HistogramCounts?
    let channels: HistogramChannels
    let ceilingStops: Double?

    static let height: CGFloat = 132

    var body: some View {
        Canvas { context, size in
            drawBackdrop(&context, size)
            let peak = ScopeMath.peak([original, current].compactMap { $0 }.flatMap(arrays))
            if let original { drawOriginal(&context, size, original, peak: peak) }
            if let current { drawCurrent(&context, size, current, peak: peak) }
            if let ceilingStops { drawCeiling(&context, size, stops: ceilingStops) }
        }
        .frame(height: Self.height)
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.sm))
        .clipShape(.rect(cornerRadius: Radius.sm))
        .overlay { ceilingLabel }
        .accessibilityHidden(true)
    }

    private func arrays(_ counts: HistogramCounts) -> [[UInt32]] {
        channels == .luma ? [counts.luma] : [counts.red, counts.green, counts.blue]
    }

    private func drawBackdrop(_ context: inout GraphicsContext, _ size: CGSize) {
        let hdrStart = ScopeScale.sdrShare * size.width
        context.fill(Path(CGRect(x: hdrStart, y: 0, width: size.width - hdrStart, height: size.height)),
                     with: .color(Color.hdr.amber.opacity(0.05)))
        for tick in ScopeScale.ticks where tick.position > 0 && tick.position < 1 {
            let isWhite = tick.position == ScopeScale.sdrShare
            var line = Path()
            line.move(to: CGPoint(x: tick.position * size.width, y: 0))
            line.addLine(to: CGPoint(x: tick.position * size.width, y: size.height))
            context.stroke(line, with: .color(isWhite ? Color.hdr.lineStrong : Color.hdr.histogramGrid), lineWidth: 1)
        }
        for share in [0.25, 0.5, 0.75] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: share * size.height))
            line.addLine(to: CGPoint(x: size.width, y: share * size.height))
            context.stroke(line, with: .color(Color.hdr.histogramGrid), lineWidth: 1)
        }
    }

    private func channelColors() -> [(Color, KeyPath<HistogramCounts, [UInt32]>)] {
        channels == .luma
            ? [(Color.hdr.histogramLuma, \.luma)]
            : [(Color.hdr.histogramRed, \.red), (Color.hdr.histogramGreen, \.green), (Color.hdr.histogramBlue, \.blue)]
    }

    /// The curve of `counts` as a polyline through the bin centres.
    private func line(_ counts: [UInt32], peak: Double, size: CGSize) -> Path {
        let values = ScopeMath.curve(counts, peak: peak)
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: (CGFloat(index) + 0.5) / CGFloat(values.count) * size.width,
                                y: ScopeMath.y(for: value, height: size.height))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }

    private func drawOriginal(_ context: inout GraphicsContext, _ size: CGSize, _ counts: HistogramCounts, peak: Double) {
        for (color, key) in channelColors() {
            let outline = line(counts[keyPath: key], peak: peak, size: size)
            var shape = outline
            shape.addLine(to: CGPoint(x: size.width, y: size.height))
            shape.addLine(to: CGPoint(x: 0, y: size.height))
            shape.closeSubpath()
            context.fill(shape, with: .color(color.opacity(channels == .luma ? 0.38 : 0.15)))
            context.stroke(outline, with: .color(color.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [5, 4]))
        }
    }

    private func drawCurrent(_ context: inout GraphicsContext, _ size: CGSize, _ counts: HistogramCounts, peak: Double) {
        let colors: [(Color, KeyPath<HistogramCounts, [UInt32]>)] =
            channels == .luma ? [(Color.hdr.histogramOutput, \.luma)] : channelColors()
        for (color, key) in colors {
            let path = line(counts[keyPath: key], peak: peak, size: size)
            // A casing in the well's colour first, so the line reads over the shapes behind it.
            context.stroke(path, with: .color(Color.hdr.histogramBackdrop),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawCeiling(_ context: inout GraphicsContext, _ size: CGSize, stops: Double) {
        let x = ScopeScale.position(stops: stops) * size.width
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Color.hdr.danger), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
    }

    @ViewBuilder private var ceilingLabel: some View {
        if let ceilingStops {
            GeometryReader { geometry in
                let x = ScopeScale.position(stops: ceilingStops) * geometry.size.width
                // To the left of the line; to the right when there is no room.
                let toLeft = x > 78
                CeilingLabel(stops: ceilingStops)
                    .frame(width: toLeft ? max(x - 3, 0) : max(geometry.size.width - x - 3, 0),
                           alignment: toLeft ? .trailing : .leading)
                    .offset(x: toLeft ? 0 : x + 3, y: 3)
            }
            .allowsHitTesting(false)
        }
    }
}

/// "Limit +2.5 EV" (or just "Limit" at SDR white), on a small plate of the
/// panel's colour so the red text reads over the curves.
struct CeilingLabel: View {
    let stops: Double

    var body: some View {
        Group {
            if let value = ScopeMath.ceilingValue(stops: stops) {
                Text("design.scope.ceiling \(value)", bundle: .module)
            } else {
                Text("design.scope.ceilingSDR", bundle: .module)
            }
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.hdr.danger)
        .lineLimit(1)
        .fixedSize()
        .padding(2)
        .background(Color.hdr.surfacePanel, in: .rect(cornerRadius: 2))
    }
}

/// The waveform's plot: luminance traces across the photograph, one column
/// of cells per slice of it, SDR rows in grey and HDR rows in amber, with
/// the export limit as a dashed red line across.
struct WaveformPlot: View {
    let waveform: WaveformCounts?
    let ceilingStops: Double?

    static let height: CGFloat = 160

    var body: some View {
        Canvas { context, size in
            let hdrHeight = (1 - ScopeScale.sdrShare) * size.height
            context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: hdrHeight)),
                         with: .color(Color.hdr.amber.opacity(0.05)))
            for tick in ScopeScale.ticks where tick.position > 0 && tick.position < 1 {
                let y = (1 - tick.position) * size.height
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                let isWhite = tick.position == ScopeScale.sdrShare
                context.stroke(line, with: .color(isWhite ? Color.hdr.lineStrong : Color.hdr.histogramGrid), lineWidth: 1)
            }
            for share in [0.25, 0.5, 0.75] {
                var line = Path()
                line.move(to: CGPoint(x: share * size.width, y: 0))
                line.addLine(to: CGPoint(x: share * size.width, y: size.height))
                context.stroke(line, with: .color(Color.hdr.histogramGrid), lineWidth: 1)
            }
            if let waveform, let mask = ScopeMath.waveformMask(waveform) {
                let image = context.resolve(Image(decorative: mask, scale: 1).interpolation(.medium))
                let plot = CGRect(origin: .zero, size: size)
                let bands: [(CGRect, Color)] = [
                    (CGRect(x: 0, y: 0, width: size.width, height: hdrHeight), Color.hdr.amber),
                    (CGRect(x: 0, y: hdrHeight, width: size.width, height: size.height - hdrHeight), Color.hdr.histogramLuma),
                ]
                for (band, tint) in bands {
                    context.drawLayer { layer in
                        layer.clip(to: Path(band))
                        layer.draw(image, in: plot)
                        layer.blendMode = .sourceIn
                        layer.fill(Path(plot), with: .color(tint))
                    }
                }
            }
            if let ceilingStops {
                let y = (1 - ScopeScale.position(stops: ceilingStops)) * size.height
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Color.hdr.danger), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
        }
        .frame(height: Self.height)
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.sm))
        .clipShape(.rect(cornerRadius: Radius.sm))
        .overlay { ceilingLabel }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var ceilingLabel: some View {
        if let ceilingStops {
            GeometryReader { geometry in
                let y = (1 - ScopeScale.position(stops: ceilingStops)) * geometry.size.height
                // Above the line at the right; below it when the line is at the top.
                let above = y > 20
                CeilingLabel(stops: ceilingStops)
                    .frame(width: geometry.size.width - 6, alignment: .trailing)
                    .offset(x: 0, y: above ? y - 20 : y + 3)
            }
            .allowsHitTesting(false)
        }
    }
}

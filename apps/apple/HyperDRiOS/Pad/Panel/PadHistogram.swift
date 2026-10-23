import HyperDRDesign
import HyperDRRender
import Observation
import SwiftUI

/// The Studio panel's histogram data (ipad-studio §3.3), measured as the Mac
/// measures its scopes (`EditorModel.startScopes`): once an edit has settled,
/// never during a drag, from a render of at most 512 pixels on the long side,
/// off the main thread, at full gain, so it is the photo's own HDR rendition
/// whatever the screen shows. The original's distribution changes only when
/// the original does.
@MainActor @Observable final class PadScopes {
    private(set) var current: HistogramData?
    private(set) var original: HistogramData?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var originalTask: Task<Void, Never>?
    @ObservationIgnored private var measured: EditorRenderRequest?
    @ObservationIgnored private var measuring: EditorRenderRequest?
    @ObservationIgnored private var measuredOriginal: EditorRenderRequest?
    @ObservationIgnored private var measuringOriginal: EditorRenderRequest?

    /// The long side of the render the histogram reads (the Mac's `scopeEdge`).
    static let edge = 512

    /// Measures what changed since the last time, if the edit has settled.
    func update(_ editor: RecipeEditor) {
        guard let source = editor.source, !editor.isDragging,
              editor.frame?.request.recipe == editor.recipe, editor.frame?.request.sourceID == source.id else { return }
        let size = Self.size(editor.canvasPhotoSize ?? source.pixelSize)
        if let request = editor.renderRequest(size: size, original: true), wants(request, original: true) {
            measuringOriginal = request
            originalTask?.cancel()
            originalTask = Task { [weak self] in
                let result = await Self.analyze(editor, request)
                guard let self, !Task.isCancelled, measuringOriginal == request else { return }
                measuringOriginal = nil
                guard let result else { return }
                measuredOriginal = request
                original = result
            }
        }
        guard let request = editor.renderRequest(size: size), wants(request, original: false) else { return }
        measuring = request
        task?.cancel()
        task = Task { [weak self] in
            let result = await Self.analyze(editor, request)
            guard let self, !Task.isCancelled, measuring == request else { return }
            measuring = nil
            guard let result else { return }
            measured = request
            current = result
        }
    }

    /// A new photo: nothing measured stands.
    func reset() {
        task?.cancel()
        originalTask?.cancel()
        measured = nil; measuring = nil; measuredOriginal = nil; measuringOriginal = nil
        current = nil
        original = nil
    }

    /// Whether `request` needs a new measurement: one of this picture done
    /// or running stands; one of another picture still running is dropped.
    private func wants(_ request: EditorRenderRequest, original: Bool) -> Bool {
        let done = original ? measuredOriginal : measured
        let running = original ? measuringOriginal : measuring
        if let running, running.rendersSame(as: request) { return false }
        guard done?.rendersSame(as: request) == true else { return true }
        if running != nil {
            if original { originalTask?.cancel(); measuringOriginal = nil } else { task?.cancel(); measuring = nil }
        }
        return false
    }

    private static func analyze(_ editor: RecipeEditor, _ request: EditorRenderRequest) async -> HistogramData? {
        guard let frame = try? await editor.renderer.render(request), !Task.isCancelled else { return nil }
        let display = frame.display
        let work = Task.detached(priority: .utility) { () -> HistogramData? in
            guard let input = try? await ScopeInput.read(display) else { return nil }
            return ScopeAnalyzer.analyze(input, waveform: false)?.histogram
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    /// `source` fitted into `edge`, never enlarged.
    static func size(_ source: HyperDRRender.PixelSize) -> HyperDRRender.PixelSize {
        let long = max(source.width, source.height)
        guard long > edge else { return source }
        let scale = Double(edge) / Double(long)
        return HyperDRRender.PixelSize(width: max(1, Int((Double(source.width) * scale).rounded())),
                                       height: max(1, Int((Double(source.height) * scale).rounded())))
    }
}

/// The histogram itself: the lower 70% of its width is SDR from black to
/// white, the upper 30% the four stops above SDR white (`ScopeScale`, the
/// Mac's ruler), drawn amber, so how much of the photo is HDR, and how far,
/// reads at a glance. The original's outline sits behind the edit. Tapping
/// switches between luminance and the three channels.
struct PadHistogram: View {
    let current: HistogramData?
    let original: HistogramData?
    @Binding var channels: HistogramChannels
    var compact = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 9 : 14, style: .continuous)
        Canvas { context, size in draw(in: &context, size: size) }
            .background(shape.fill(Color.black.opacity(0.32)))
            .clipShape(shape)
            .overlay(alignment: .bottomLeading) { if !compact { labels } }
            .overlay {
                if current == nil {
                    ProgressView().controlSize(.small).opacity(0.6)
                }
            }
            .contentShape(shape)
            .onTapGesture {
                withAnimation(.smooth(duration: 0.2)) { channels = channels == .luma ? .rgb : .luma }
            }
            .animation(.smooth(duration: 0.25), value: current)
            .accessibilityElement()
            .accessibilityLabel(Text("ipad.histogram"))
            .accessibilityAddTraits(.isButton)
    }

    /// "SDR" under the SDR part, "HDR" under the stops above white.
    private var labels: some View {
        GeometryReader { proxy in
            let split = proxy.size.width * ScopeScale.sdrShare
            ZStack(alignment: .bottomLeading) {
                Text(verbatim: "SDR")
                    .foregroundStyle(Color.white.opacity(0.45))
                    .offset(x: 8)
                Text(verbatim: "HDR")
                    .foregroundStyle(Color.hdr.amber.opacity(0.85))
                    .offset(x: split + 6)
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.bottom, 5)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let split = size.width * ScopeScale.sdrShare
        // The stops above SDR white, and white itself.
        context.fill(Path(CGRect(x: split, y: 0, width: size.width - split, height: size.height)),
                     with: .color(Color.hdr.amber.opacity(0.07)))
        var line = Path()
        line.move(to: CGPoint(x: split, y: 0))
        line.addLine(to: CGPoint(x: split, y: size.height))
        context.stroke(line, with: .color(Color.hdr.amber.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        guard let current else { return }
        let peak = Self.peak([current.luma] + (channels == .rgb ? [current.red, current.green, current.blue] : []))
        let inset = CGRect(x: 0, y: compact ? 3 : 8, width: size.width, height: size.height - (compact ? 4 : 10))
        if let original {
            context.stroke(Self.curve(original.luma, peak: Self.peak([original.luma]), in: inset, closed: false),
                           with: .color(Color.white.opacity(0.28)), lineWidth: 1)
        }
        switch channels {
        case .luma:
            let area = Self.curve(current.luma, peak: peak, in: inset, closed: true)
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: 0, y: 0, width: split, height: size.height)))
                layer.fill(area, with: .color(Color.white.opacity(0.62)))
            }
            context.drawLayer { layer in
                layer.clip(to: Path(CGRect(x: split, y: 0, width: size.width - split, height: size.height)))
                layer.fill(area, with: .color(Color.hdr.amber.opacity(0.9)))
            }
        case .rgb:
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                for (bins, color) in [(current.red, Color.red), (current.green, Color.green), (current.blue, Color.blue)] {
                    layer.fill(Self.curve(bins, peak: peak, in: inset, closed: true), with: .color(color.opacity(0.55)))
                }
            }
        }
    }

    /// The count a full-height bin stands for: the 99th percentile of the
    /// non-empty bins, so one spike (clipped white, a black border) does not
    /// flatten the rest.
    private static func peak(_ sets: [[UInt32]]) -> Double {
        let counts = sets.flatMap { $0 }.filter { $0 > 0 }.sorted()
        guard !counts.isEmpty else { return 1 }
        return Double(counts[min(counts.count - 1, Int(Double(counts.count) * 0.99))])
    }

    /// The bins as a smoothed outline (or area) across `rect`, heights on a
    /// square-root scale so the faint tails stay visible.
    private static func curve(_ bins: [UInt32], peak: Double, in rect: CGRect, closed: Bool) -> Path {
        let count = bins.count
        guard count > 1, peak > 0 else { return Path() }
        func height(_ index: Int) -> CGFloat {
            let lower = max(0, index - 1), upper = min(count - 1, index + 1)
            let sum = (lower...upper).reduce(0.0) { $0 + Double(bins[$1]) }
            let value = sum / Double(upper - lower + 1)
            return CGFloat(min(1, (value / peak).squareRoot())) * rect.height
        }
        var path = Path()
        let step = rect.width / CGFloat(count - 1)
        if closed { path.move(to: CGPoint(x: rect.minX, y: rect.maxY)) }
        for index in 0..<count {
            let point = CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.maxY - height(index))
            if index == 0, !closed { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

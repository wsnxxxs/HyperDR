import SwiftUI

/// The inspector's scopes: a histogram of the photo before and after the
/// adjustments, or a luminance waveform, on one ruler (`ScopeScale`), with
/// the export limit marked and two zebra switches underneath.
///
/// Expanded, a title row switches between histogram and waveform (and, for
/// the histogram, luma and RGB) and collapses the panel; then a legend line,
/// the plot, and the switches. Collapsed, it is one row. The plot area is
/// the same height for both scopes, so switching does not move what is
/// below. Before the first measurement it says so; when the preview failed
/// it says that; neither draws made-up curves, and the zebra switches rest.
///
/// The caller owns every piece of state, so it can keep the scope kind and
/// whether it is collapsed for the whole run, and the zebra switches are
/// the same ones as the View menu's.
public struct ScopePanel: View {
    @Binding private var kind: ScopeKind
    @Binding private var channels: HistogramChannels
    @Binding private var isExpanded: Bool
    @Binding private var highlightZebra: Bool
    @Binding private var shadowZebra: Bool
    private let content: ScopeContent
    private let ceilingStops: Double?

    /// `ceilingStops`: the most the export can show above SDR white, where
    /// the red limit line goes; 0 for colour-only processing, nil for none.
    public init(kind: Binding<ScopeKind>, channels: Binding<HistogramChannels>, isExpanded: Binding<Bool>,
                highlightZebra: Binding<Bool>, shadowZebra: Binding<Bool>, content: ScopeContent,
                ceilingStops: Double?) {
        _kind = kind
        _channels = channels
        _isExpanded = isExpanded
        _highlightZebra = highlightZebra
        _shadowZebra = shadowZebra
        self.content = content
        self.ceilingStops = ceilingStops
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded { expanded } else { collapsed }
        }
        .padding(EdgeInsets(top: 12, leading: 20, bottom: isExpanded ? 16 : 12, trailing: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("design.scope.title", bundle: .module))
    }

    // MARK: Collapsed

    private var collapsed: some View {
        Button {
            withHDRAnimation { isExpanded = true }
        } label: {
            HStack(spacing: 8) {
                Text("design.scope.title", bundle: .module)
                    .font(.system(size: TypeScale.Size.caption, weight: .semibold))
                    .foregroundStyle(Color.hdr.ink)
                Text(kind == .histogram ? "design.scope.histogram" : "design.scope.waveform", bundle: .module)
                    .font(.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.hdr.inkMuted)
                    .rotationEffect(.degrees(-90))
                    .accessibilityHidden(true)
            }
            .frame(height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(Text("design.scope.expand", bundle: .module))
        .accessibilityLabel(Text("design.scope.title", bundle: .module))
        .accessibilityValue(Text("design.group.collapsed", bundle: .module))
        .accessibilityHint(Text("design.scope.expand", bundle: .module))
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            legend.frame(height: 14).padding(.top, 8)
            plot.padding(.top, 6)
            HStack(spacing: 6) {
                ZebraSwitch(.highlights, isOn: $highlightZebra)
                ZebraSwitch(.shadows, isOn: $shadowZebra)
            }
            .disabled(!hasData)
            .padding(.top, 12)
        }
    }

    private var hasData: Bool {
        if case .data = content { return true }
        return false
    }

    private var titleRow: some View {
        HStack(spacing: 6) {
            ParameterSegmented(Text("design.scope.kind", bundle: .module), selection: $kind, choices: [
                SegmentedChoice(Text("design.scope.histogram", bundle: .module), value: ScopeKind.histogram),
                SegmentedChoice(Text("design.scope.waveform", bundle: .module), value: ScopeKind.waveform),
            ], size: .small, fillsWidth: false)
            if kind == .histogram {
                ParameterSegmented(Text("design.scope.channels", bundle: .module), selection: $channels, choices: [
                    SegmentedChoice(Text("design.scope.luma", bundle: .module), value: HistogramChannels.luma),
                    SegmentedChoice(Text("design.scope.rgb", bundle: .module), value: HistogramChannels.rgb),
                ], size: .small, fillsWidth: false)
            }
            Spacer(minLength: 0)
            Button {
                withHDRAnimation { isExpanded = false }
            } label: {
                CollapseGlyph()
            }
            .buttonStyle(.plain)
            .help(Text("design.scope.collapse", bundle: .module))
            .accessibilityLabel(Text("design.scope.collapse", bundle: .module))
        }
        .frame(height: 24)
    }

    // MARK: Legend

    @ViewBuilder private var legend: some View {
        if hasData {
            HStack(spacing: 12) {
                if kind == .histogram {
                    HStack(spacing: 5) {
                        OriginalSwatch(channels: channels)
                        Text("design.scope.original", bundle: .module)
                    }
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(channels == .luma ? Color.hdr.histogramOutput : Color.hdr.inkMuted)
                            .frame(width: 12, height: 2)
                            .accessibilityHidden(true)
                        Text("design.scope.edited", bundle: .module)
                    }
                } else {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(LinearGradient(colors: [Color.hdr.inkMuted, Color.hdr.histogramOutput],
                                                 startPoint: .bottom, endPoint: .top))
                            .frame(width: 6, height: 12)
                            .accessibilityHidden(true)
                        Text("design.scope.waveformLegend", bundle: .module)
                    }
                }
            }
            .font(.hdr.caption)
            .foregroundStyle(Color.hdr.inkMuted)
            .lineLimit(1)
        } else {
            Color.clear
        }
    }

    // MARK: Plot

    @ViewBuilder private var plot: some View {
        switch kind {
        case .histogram:
            VStack(alignment: .leading, spacing: 4) {
                histogramWell
                GeometryReader { geometry in
                    ScopeAxisRamp(orientation: .horizontal, length: geometry.size.width)
                }
                .frame(height: ScopeAxisRamp.horizontalHeight)
            }
        case .waveform:
            HStack(spacing: 0) {
                ScopeAxisRamp(orientation: .vertical, length: WaveformPlot.height)
                waveformWell
            }
        }
    }

    @ViewBuilder private var histogramWell: some View {
        switch content {
        case .data(let data):
            HistogramPlot(original: data.original, current: data.current, channels: channels, ceilingStops: ceilingStops)
        case .measuring:
            placeholder(height: HistogramPlot.height, measuring: true)
        case .unavailable:
            placeholder(height: HistogramPlot.height, measuring: false)
        }
    }

    @ViewBuilder private var waveformWell: some View {
        switch content {
        case .data(let data):
            WaveformPlot(waveform: data.waveform, ceilingStops: ceilingStops)
        case .measuring:
            placeholder(height: WaveformPlot.height, measuring: true)
        case .unavailable:
            placeholder(height: WaveformPlot.height, measuring: false)
        }
    }

    private func placeholder(height: CGFloat, measuring: Bool) -> some View {
        HStack(spacing: 6) {
            if measuring { ProgressView().controlSize(.mini) }
            Text(measuring ? "design.scope.measuring" : "design.scope.unavailable", bundle: .module)
                .font(.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Color.hdr.histogramBackdrop, in: .rect(cornerRadius: Radius.sm))
    }
}

/// The 20 × 20 hit area and chevron of the collapse button.
private struct CollapseGlyph: View {
    @State private var hovered = false

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted)
            .frame(width: 20, height: 20)
            .contentShape(.rect)
            .onHover { hovered = $0 }
            .hdrAnimation(Motion.fast, value: hovered)
    }
}

/// The legend's mark for the original frame: a filled, dash-outlined chip,
/// as the histogram draws it.
private struct OriginalSwatch: View {
    let channels: HistogramChannels

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.hdr.histogramLuma.opacity(channels == .luma ? 0.38 : 0.25))
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.hdr.histogramLuma.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(width: 12, height: 8)
            .accessibilityHidden(true)
    }
}

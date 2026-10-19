import SwiftUI
import HyperDRDesign

/// The scope panel at the top of the inspector: the histogram or waveform of
/// the edited preview with the original's histogram behind it, the export
/// limit, and the two zebra switches (the View menu's, the same two model
/// properties). The scope's kind, channels and folded state live in the
/// run-wide `ViewerSessionState`.
struct ScopeSection: View {
    let model: EditorModel
    @Environment(ViewerSessionState.self) private var session

    var body: some View {
        @Bindable var session = session
        ScopePanel(kind: $session.scopeKind, channels: $session.scopeChannels,
                   isExpanded: $session.isScopeExpanded,
                   highlightZebra: Binding(get: { model.showsHighlightZebra }, set: { model.showsHighlightZebra = $0 }),
                   shadowZebra: Binding(get: { model.showsShadowZebra }, set: { model.showsShadowZebra = $0 }),
                   content: Self.content(scopes: model.scopes, phase: model.document?.phase),
                   ceilingStops: model.hasEditedFrame ? model.outputCeilingStops : nil)
    }

    /// Measured data once there is any, "preview failed" for a photo without
    /// a frame, otherwise "measuring".
    static func content(scopes: ScopeState, phase: DocumentPhase?) -> ScopeContent {
        if let current = scopes.current {
            return .data(ScopeData(original: scopes.original.map(HistogramCounts.init),
                                   current: HistogramCounts(current),
                                   waveform: scopes.waveform.map(WaveformCounts.init)))
        }
        if case .failed? = phase { return .unavailable }
        return .measuring
    }
}

extension HistogramCounts {
    init(_ data: HistogramData) {
        self.init(luma: data.luma, red: data.red, green: data.green, blue: data.blue)
    }
}

extension WaveformCounts {
    init(_ data: WaveformData) {
        self.init(columns: data.columns, rows: WaveformData.rows, counts: data.counts)
    }
}

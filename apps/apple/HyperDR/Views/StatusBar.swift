import SwiftUI
import HyperDRDesign

/// The strip under the canvas: engine state, the photograph's kind, what the
/// display is showing, and the zoom. Keyboard shortcuts live in the menus, so
/// the web's shortcut button has no counterpart here.
struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: Space.s4) {
            engine
            if model.workspace == .editing {
                HStack(spacing: Space.s4) {
                    if let source = model.document?.source {
                        Text(source.domain.label)
                    }
                    displayText
                }
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: Space.s4)
            ZoomControls(canvas: model.canvas)
                .layoutPriority(1)
        }
        .font(Font.hdr.caption)
        .foregroundStyle(Color.hdr.inkMuted)
        .padding(.horizontal, Space.s4)
        .frame(height: Layout.statusBarHeight)
        .background(Color.hdr.surfacePanel)
        .overlay(alignment: .top) { Divider() }
    }

    /// "HDR display · now 2.4×, up to 10.2×", that an SDR display
    /// previews in SDR, or that the preview is SDR on purpose (View ▸ Preview
    /// as SDR; the export is not affected). Follows the display as its headroom changes (the
    /// model throttles this to about 4 Hz).
    private var displayText: some View {
        let display = model.display
        if model.previewsAsSDR { return Text("status.sdrPreview").help(Text(verbatim: display.screenName)) }
        let text = display.supportsEDR
            ? Text("mac.display.edr \(Self.headroom(display.currentHeadroom)) \(Self.headroom(display.potentialHeadroom))")
            : Text("mac.display.sdr")
        return text.help(Text(verbatim: display.screenName))
    }

    private static func headroom(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "×"
    }

    @ViewBuilder private var engine: some View {
        switch model.engine {
        case .starting:
            HStack(spacing: Space.s2) {
                ProgressView().controlSize(.mini)
                Text("mac.engine.starting")
            }
        case .ready(let version):
            HStack(spacing: Space.s2) {
                Circle().fill(Color.hdr.successLine).frame(width: 7, height: 7)
                Text("app.service.ready")
            }
            .help(Text(verbatim: "HyperDR \(version)"))
        case .failed(let error):
            let text = ErrorText(error)
            HStack(spacing: Space.s2) {
                Circle().fill(Color.hdr.danger).frame(width: 7, height: 7)
                Text(text.title)
                    .foregroundStyle(Color.hdr.danger)
            }
            .help(Text(verbatim: text.body))
        }
    }
}

/// Fit, zoom out, the zoom level and zoom in, bound to the canvas. Without a
/// photo on the canvas there is nothing to zoom and all of it is disabled.
/// Fit appears only once the photo is zoomed: at the fitted size the readout
/// already says "Fit", and a dimmed "Fit Window" beside it read as a second,
/// broken control.
private struct ZoomControls: View {
    let canvas: CanvasModel

    var body: some View {
        let hasPhoto = canvas.imageFrame != nil
        HStack(spacing: Space.s1) {
            if hasPhoto && canvas.zoom != .fit {
                // The bar's muted foreground would otherwise hide that it is a link.
                Button("editor.fit") { canvas.fitToWindow() }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.hdr.accent)
                    .padding(.trailing, Space.s2)
            }
            Button("editor.zoomOut", systemImage: "minus") { canvas.zoomOut() }
                .labelStyle(.iconOnly)
                .disabled(!canvas.canZoomOut)
            readout(hasPhoto: hasPhoto)
            Button("editor.zoomIn", systemImage: "plus") { canvas.zoomIn() }
                .labelStyle(.iconOnly)
                .disabled(!canvas.canZoomIn)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    /// "Fit" at the fitted size, else the share of the photo's own pixels
    /// (one source pixel per backing pixel is 100%).
    private func readout(hasPhoto: Bool) -> some View {
        Group {
            if !hasPhoto {
                Text(verbatim: "—")
            } else {
                switch canvas.zoomReadout {
                case .fit: Text("status.zoomFit")
                case .percent(let value): Text(verbatim: "\(value)%")
                }
            }
        }
        .font(Font.hdr.readout)
        .foregroundStyle(hasPhoto ? Color.hdr.ink : Color.hdr.inkDisabled)
        .frame(minWidth: 42)
        .help("editor.zoomHint")
    }
}

import SwiftUI
import HyperDRDesign

/// The strip under the canvas: engine state and, with a photograph, its kind.
/// Keyboard shortcuts live in the menus, so the web's shortcut button has no
/// counterpart here. What the display is showing and the zoom controls join
/// in F3, once they are bound to the display and canvas models.
struct StatusBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: Space.s4) {
            engine
            if model.workspace == .editing, let source = model.document?.source {
                Text(source.domain.label)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s4)
        }
        .font(Font.hdr.caption)
        .foregroundStyle(Color.hdr.inkMuted)
        .padding(.horizontal, Space.s4)
        .frame(height: Layout.statusBarHeight)
        .background(Color.hdr.surfacePanel)
        .overlay(alignment: .top) { Divider() }
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

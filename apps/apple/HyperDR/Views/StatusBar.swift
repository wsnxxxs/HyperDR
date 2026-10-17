import SwiftUI
import HyperDRDesign

/// The strip under the canvas and inspector: engine state, what the display is
/// showing, and the zoom. Keyboard shortcuts live in the menus, so the web's
/// shortcut button has no counterpart here.
struct StatusBar: View {
    var workspace: Workspace

    var body: some View {
        HStack(spacing: Space.s4) {
            HStack(spacing: Space.s2) {
                Circle().fill(Color.hdr.successLine).frame(width: 7, height: 7)
                Text("app.service.ready")
            }
            if workspace == .editing {
                HStack(spacing: Space.s2) {
                    Text("stage.input.hdr")
                    Text("mac.display.edr \("4.0×") \("10.2×")")
                }
                .lineLimit(1)
                Spacer(minLength: Space.s4)
                zoom
            } else {
                Spacer()
            }
        }
        .font(Font.hdr.caption)
        .foregroundStyle(Color.hdr.inkMuted)
        .padding(.horizontal, Space.s4)
        .frame(height: Layout.statusBarHeight)
        .background(Color.hdr.surfacePanel)
        .overlay(alignment: .top) { Divider() }
    }

    private var zoom: some View {
        HStack(spacing: Space.s1) {
            Button("editor.fit") {}
                .buttonStyle(.link)
                .padding(.trailing, Space.s2)
            Button("editor.zoomOut", systemImage: "minus") {}
                .labelStyle(.iconOnly)
            Text(verbatim: "100%")
                .font(Font.hdr.readout)
                .foregroundStyle(Color.hdr.ink)
                .frame(minWidth: 42)
                .help("editor.zoomHint")
            Button("editor.zoomIn", systemImage: "plus") {}
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

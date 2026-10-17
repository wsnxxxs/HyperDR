import SwiftUI
import HyperDRDesign

/// The recessed workspace: the drop area and picker without a photograph, the
/// EDR preview with one. Both accept a photo dropped from Finder.
struct CanvasView: View {
    let model: EditorModel
    let window: EditorWindowState
    var padding: CGFloat

    @State private var drop = PhotoDropState.idle

    var body: some View {
        Group {
            switch model.workspace {
            case .editing: viewport
            case .empty: DropTarget(model: model, window: window, drop: drop)
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hdr.surfacePage)
        .onDrop(of: [.fileURL], delegate: PhotoDropDelegate(model: model, state: $drop))
    }

    private var viewport: some View {
        PreviewCanvas(model: model)
            .padding(Layout.canvasGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hdr.previewBackdrop, in: .rect(cornerRadius: Radius.standard))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard)
                    .strokeBorder(drop.borderColor(idle: Color.hdr.line), lineWidth: drop == .idle ? 1 : 2)
            }
            .overlay(alignment: .bottom) {
                if drop == .rejects {
                    Label("mac.drop.unsupported", systemImage: "nosign")
                        .font(Font.hdr.control)
                        .hdrOverlayChip()
                        .padding(Space.s4)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("stage.label")
    }
}

private extension PhotoDropState {
    func borderColor(idle: Color) -> Color {
        switch self {
        case .idle: idle
        case .accepts: Color.hdr.accent
        case .rejects: Color.hdr.danger
        }
    }
}

/// The empty canvas: drop a photograph here or pick one.
private struct DropTarget: View {
    let model: EditorModel
    let window: EditorWindowState
    let drop: PhotoDropState

    var body: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: drop == .rejects ? "nosign" : "photo.badge.plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(drop == .rejects ? Color.hdr.danger : Color.hdr.inkMuted)
            VStack(spacing: Space.s2) {
                Text(drop == .rejects ? "mac.drop.unsupported" : "stage.empty")
                    .font(Font.hdr.title)
                    .foregroundStyle(Color.hdr.inkStrong)
                Text("workspace.emptyDescription")
                    .font(Font.hdr.control)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .multilineTextAlignment(.center)
                Text("stage.support")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
                    .help(Text(verbatim: supportedExtensions))
            }
            if let failure = model.engine.failure {
                engineFailure(ErrorText(failure))
            } else {
                Button("stage.select") { window.isImporting = true }
                    .buttonStyle(.hdrPrimary)
                    .padding(.top, Space.s2)
                Text("mac.empty.dropHint")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Text("editor.local")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .padding(.top, Space.s2)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hdr.surfaceSunken.opacity(0.5), in: .rect(cornerRadius: Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(drop.borderColor(idle: Color.hdr.lineStrong),
                              style: StrokeStyle(lineWidth: drop == .idle ? 1.5 : 2, dash: drop == .idle ? [6, 5] : []))
        }
    }

    /// The engine is down: say so where the picker would be.
    private func engineFailure(_ text: ErrorText) -> some View {
        VStack(spacing: Space.s1) {
            Label { Text(text.title) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(Font.hdr.controlLabel)
                .foregroundStyle(Color.hdr.danger)
            Text(verbatim: text.body)
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.top, Space.s2)
    }

    /// Every extension the picker accepts, for the support line's tooltip.
    private var supportedExtensions: String {
        model.openableContentTypes
            .flatMap { $0.tags[.filenameExtension] ?? [] }
            .map { "." + $0 }
            .joined(separator: " ")
    }
}

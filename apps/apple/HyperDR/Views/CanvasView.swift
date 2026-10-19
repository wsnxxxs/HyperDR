import SwiftUI
import HyperDRDesign

/// The recessed workspace: the drop area and picker without a photograph, the
/// EDR preview on its backdrop with one. Both accept a photo dropped from
/// Finder.
struct CanvasView: View {
    let model: EditorModel
    let window: EditorWindowState
    var padding: CGFloat
    var showsInspector = true

    @State private var dropCoordinator = PhotoDropCoordinator()

    private var drop: PhotoDropState { dropCoordinator.state }

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
        .onDrop(of: [.fileURL], delegate: PhotoDropDelegate(model: model, coordinator: dropCoordinator))
    }

    /// What the drag over the canvas says: refused, or (while an export runs)
    /// that releasing will ask about stopping it.
    private var dropNotice: DropNotice? {
        if drop == .rejects { return .rejects }
        if drop == .accepts, model.export.isInFlight, let name = dropCoordinator.firstName { return .replacesDuringExport(name: name) }
        return nil
    }

    private var viewport: some View {
        CanvasStage(model: model, window: window, showsInspector: showsInspector, dropNotice: dropNotice)
            .padding(Layout.canvasGutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hdr.previewBackdrop, in: .rect(cornerRadius: Radius.lg))
            .clipShape(.rect(cornerRadius: Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(drop.borderColor(idle: Color.hdr.line), lineWidth: drop == .idle ? 1 : 2)
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
            if model.notice == .clipboardImageUnsupported {
                Text("paste.imageData")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        if !Task.isCancelled, model.notice == .clipboardImageUnsupported { model.notice = nil }
                    }
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

/// What a drag over the canvas says in its chip at the canvas's foot.
enum DropNotice: Equatable {
    case rejects
    case replacesDuringExport(name: String)
}

struct DropNoticeChip: View {
    let notice: DropNotice

    var body: some View {
        switch notice {
        case .rejects:
            Label("mac.drop.unsupported", systemImage: "nosign")
                .font(Font.hdr.control)
                .hdrOverlayChip()
        case .replacesDuringExport(let name):
            // Accepted, not refused: releasing asks whether to stop the export.
            VStack(spacing: 2) {
                Label("switchPhoto.drop \(name)", systemImage: "arrow.down.doc")
                    .font(Font.hdr.control)
                Text("switchPhoto.dropNote")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.overlayMuted)
            }
            .hdrOverlayChip()
        }
    }
}

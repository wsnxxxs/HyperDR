import SwiftUI
import HyperDRDesign
import HyperDRRecipe

/// The trailing inspector: the scopes on top, then the photograph's facts,
/// the AI status and the adjustment groups. Without a photograph it shows the
/// three steps instead.
///
/// The controls are generated from the recipe's declarations
/// (`AdjustmentInspector`) and write the editor's recipe; the editor makes
/// the undo steps.
struct InspectorView: View {
    let model: EditorModel
    var window = EditorWindowState()

    var body: some View {
        ScrollView {
            InspectorContent(model: model, window: window)
        }
        .background(Color.hdr.surfacePanel)
        // Pinned above the scrolling inspector: the export's status card.
        .safeAreaInset(edge: .top, spacing: 0) {
            ExportStatusHost(model: model, window: window)
                .background(Color.hdr.surfacePanel)
        }
    }
}

/// The inspector's column, without the scroll view around it (which a
/// snapshot cannot size).
struct InspectorContent: View {
    let model: EditorModel
    var window = EditorWindowState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.workspace == .editing, let document = model.document {
                ScopeSection(model: model)
                Divider()
                ExportLockRegion(model: model, window: window) {
                    VStack(alignment: .leading, spacing: 0) {
                        PhotoInfoSection(document: document)
                        Divider()
                        AIStatusLine(editor: model.editor)
                        Adjustments(model: model)
                            .disabled(model.isEditingLocked)
                    }
                }
            } else {
                Welcome()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Photo

/// What M1 knows about the open photograph: the file's own facts, then what
/// the decoder reported with the reference frame. A fact not known yet reads
/// as a dash.
private struct PhotoInfoSection: View {
    let document: DocumentState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("mac.info.title")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s4, verticalSpacing: Space.s2) {
                row("mac.info.dimensions", dimensions.map { Text(verbatim: $0) })
                row("mac.info.format", Text(verbatim: document.formatLabel))
                row("mac.info.size", fileSize.map { Text(verbatim: $0) })
                row("mac.info.type", document.source.map { Text($0.domain.label) })
                row("mac.info.color", document.source.flatMap { $0.colorName.isEmpty ? nil : Text(verbatim: $0.colorName) })
            }
            if let reasons = document.source?.degradationReasons, let sentence = DecodeDegradation.text(reasons) {
                Label {
                    Text(sentence)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.warn)
            }
        }
        .padding(20)
    }

    private func row(_ title: LocalizedStringKey, _ value: Text?) -> some View {
        GridRow {
            Text(title)
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
            (value ?? Text(verbatim: "—"))
                .font(Font.hdr.readout)
                .foregroundStyle(Color.hdr.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var dimensions: String? {
        document.pixelSize.map { "\($0.width) × \($0.height)" }
    }

    private var fileSize: String? {
        document.byteCount > 0 ? document.byteCount.formatted(.byteCount(style: .file)) : nil
    }
}

extension InputDomain {
    /// The photograph's kind as the status bar and inspector name it.
    var label: LocalizedStringKey {
        switch self {
        case .sceneReferred: "stage.input.scene"
        case .sdr: "stage.input.sdr"
        case .hdr: "stage.input.hdr"
        case .dual: "stage.input.dual"
        case .unknown: "stage.input.unknown"
        }
    }
}

// MARK: - Empty

private struct Welcome: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("welcome.title")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.hdr.inkStrong)
            Text("mac.welcome.description")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.inkMuted)
                .lineSpacing(5)
                .padding(.top, 10)
            VStack(alignment: .leading, spacing: 26) {
                Step(number: "01", title: "welcome.import", note: "welcome.importNote")
                Step(number: "02", title: "welcome.adjust", note: "welcome.adjustNote")
                Step(number: "03", title: "welcome.export", note: "welcome.exportNote")
            }
            .padding(.top, Space.s6)
        }
        .padding(EdgeInsets(top: 28, leading: Layout.panelPadding, bottom: 28, trailing: Layout.panelPadding))
    }

    private struct Step: View {
        var number: String
        var title: LocalizedStringKey
        var note: LocalizedStringKey

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Text(verbatim: number)
                    .font(Font.hdr.mono())
                    .foregroundStyle(Color.hdr.inkMuted)
                    .frame(width: 26, alignment: .leading)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(.system(size: TypeScale.Size.control, weight: .medium))
                        .foregroundStyle(Color.hdr.ink)
                    Text(note)
                        .font(Font.hdr.caption)
                        .foregroundStyle(Color.hdr.inkMuted)
                }
            }
        }
    }
}

// MARK: - Adjustments

/// The generated controls on the editor's recipe. Group resets and Reset All
/// go through the editor so their undo steps are named for what they did.
private struct Adjustments: View {
    let model: EditorModel

    var body: some View {
        let editor = model.editor
        AdjustmentInspector(
            recipe: Binding(get: { editor.recipe }, set: { editor.setRecipe($0) }),
            panel: AdjustmentPanel(context: AdjustmentContext(
                sourceValues: editor.source?.sourceValues ?? [:],
                automaticValues: editor.automaticValues,
                capabilities: editor.source?.capabilities ?? [],
                unavailableOptions: editor.unavailableOptions,
                luts: model.lutChoices)),
            style: .pointer,
            onEditingChanged: { editor.editingChanged($0, $1) },
            onReset: { reset in
                switch reset {
                case .group(let group): editor.resetGroup(group)
                case .all: editor.resetAll()
                }
            })
    }
}

/// Under the HDR source: what AI is doing, when it is doing anything
/// (p7-2b §9). Editing is never paused for it.
private struct AIStatusLine: View {
    let editor: RecipeEditor

    var body: some View {
        if let key {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                if editor.aiStatus == .computing { ProgressView().controlSize(.mini) }
                Text(key)
                    .font(Font.hdr.caption)
                    .foregroundStyle(isProblem ? Color.hdr.warn : Color.hdr.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if case .failed = editor.aiStatus {
                    Button("ai.status.retry") { editor.retryModelGain() }
                        .buttonStyle(.hdrCompact(.link))
                }
            }
            .help(detail.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
            .padding(.horizontal, Layout.panelPadding)
            .padding(.vertical, Space.s3)
        }
    }

    private var usesAI: Bool { editor.recipe.hdrSource.usesModel }

    private var key: LocalizedStringKey? {
        switch editor.aiStatus {
        case .computing: return usesAI ? "ai.status.predicting" : nil
        case .failed: return usesAI ? "ai.status.predictFailed" : nil
        case .unavailable: return "ai.status.modelUnavailable"
        case .ready: return usesAI && editor.isModelGainPending ? "ai.status.notApplied" : nil
        case .idle: return nil
        }
    }

    private var isProblem: Bool {
        switch editor.aiStatus {
        case .failed, .unavailable: true
        default: false
        }
    }

    /// The developer-facing reason, as a tooltip.
    private var detail: String? {
        switch editor.aiStatus {
        case .failed(let reason), .unavailable(let reason): reason
        default: nil
        }
    }
}

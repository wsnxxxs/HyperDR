import SwiftUI
import HyperDRDesign

/// The card at the top of the inspector (M3 §5.1, §7.2): while an export
/// runs, what it is doing and how far it has got; once it ends, what came of
/// it. It stays until the user closes it, and never goes by itself.
struct ExportStatusHost: View {
    let model: EditorModel
    let window: EditorWindowState

    @Environment(\.locale) private var locale

    var body: some View {
        switch model.export.phase {
        case .idle, .cancelled:
            EmptyView()
        case .preparing, .running, .finishing, .saving:
            card.padding(Space.s3)
        case .succeeded, .failed:
            card.padding(Space.s3)
        }
    }

    /// The one line under the card's "Export failed": the error's own headline,
    /// or, when that is the same two words (the generic code), the first
    /// sentence of what it says, so the card never repeats its title.
    static func failureLine(_ failure: UserFacingError, locale: Locale) -> String {
        let text = ErrorText(failure)
        let generic = ErrorText(UserFacingError(code: "export_failed"))
        guard text.title(locale: locale) == generic.title(locale: locale) else { return text.title(locale: locale) }
        let body = text.body(locale: locale)
        let end = body.firstIndex { "\u{3002}.!\u{FF01}".contains($0) }
        return end.map { String(body[...$0]) } ?? body
    }

    @ViewBuilder private var card: some View {
        if model.export.isInFlight {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let estimate = model.export.estimate(at: model.now())
                let parts = ExportPresentation.statusParts(phase: model.export.phase, stage: model.export.stage,
                                                          workflow: model.workflow, estimate: estimate)
                ExportStatusCard(
                    kind: model.export.isStopping ? .stopping : .running,
                    fileName: ExportPresentation.fileName(for: model),
                    statusLine: Text(verbatim: ExportPresentation.statusLine(
                        parts, elapsed: model.export.startedAt.map { model.now().timeIntervalSince($0) } ?? 0,
                        locale: locale)),
                    percent: ExportPresentation.percent(estimate: estimate, isDone: false),
                    progress: ExportPresentation.progressStyle(isStopping: model.export.isStopping, estimate: estimate),
                    emphasis: window.isEmphasizingLock,
                    onStop: model.export.isStopping ? nil : { model.cancelExport() },
                    onDetails: window.openExport)
            }
        } else if let failure = model.export.failure, model.export.phase == .failed {
            ExportStatusCard(kind: .failed(title: Text(verbatim: Self.failureLine(failure, locale: locale))),
                             fileName: ExportPresentation.fileName(for: model),
                             onDetails: window.openExport, onDismiss: model.export.dismissOutcome)
        } else if let result = model.export.result {
            ExportStatusCard(
                kind: model.export.saveFailure != nil ? .saveFailed : .exported(savedTo: ExportPresentation.savedFolder(result.saved, locale: locale)),
                fileName: result.fileName, isStale: model.export.isResultStale, onDetails: window.openExport,
                onSave: { ExportFlow.saveAs(model: model, version: result.export,
                                            choosePlace: ExportSavePanel.chooser(on: NSApp.keyWindow)) },
                onShowInFinder: { ExportFlow.showInFinder(model: model, version: result.export) },
                canShowInFinder: ExportFlow.canShowInFinder(model: model, version: result.export),
                onDismiss: model.export.dismissOutcome)
        }
    }
}

/// The inspector's locked part (M3 §5.2): while an export runs, a clear
/// layer over the controls takes the press or drag a disabled control would
/// swallow and answers with the status card's flash. One tooltip covers the
/// whole region; it is the layer's own, so no empty tooltip of a control
/// underneath can hide it and the content keeps its identity. The layer sits
/// inside the scroll view's content, so the wheel still scrolls the inspector.
struct ExportLockRegion<Content: View>: View {
    let model: EditorModel
    let window: EditorWindowState
    @ViewBuilder var content: Content

    var body: some View {
        let locked = model.editingLockReason == .exporting
        content
            .overlay { if locked { LockCatcher(window: window) } }
    }
}

private struct LockCatcher: View {
    let window: EditorWindowState
    @State private var pressed = false

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    window.emphasizeLock()
                }
                .onEnded { _ in pressed = false })
            .help(Text("exportLock.help"))
            .accessibilityHidden(true)
    }
}

/// The canvas's capsule while the inspector is hidden (M3 §5.4): the
/// export's progress and a Stop button, flashing like the card when the user
/// touches what is locked.
struct ExportCanvasCapsule: View {
    let model: EditorModel
    let window: EditorWindowState
    /// How far the card (or chip) at the canvas's foot lifts the capsule.
    var lift: CGFloat = 0

    @Environment(\.locale) private var locale

    var body: some View {
        if model.export.isInFlight {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let estimate = model.export.estimate(at: model.now())
                let parts = ExportPresentation.statusParts(phase: model.export.phase, stage: model.export.stage,
                                                          workflow: model.workflow, estimate: estimate)
                HStack(spacing: Space.s3) {
                    Label {
                        Text(verbatim: ExportPresentation.capsuleText(estimate: estimate, parts: parts, locale: locale))
                    } icon: {
                        Image(systemName: "lock.fill")
                    }
                    Button("exportLock.canvasStop") { model.cancelExport() }
                        .buttonStyle(.hdrCompact(.link))
                        .disabled(model.export.isStopping)
                }
                .font(Font.hdr.control)
                .hdrOverlayChip()
                .overlay {
                    Capsule().strokeBorder(Color.hdr.accent, lineWidth: window.isEmphasizingLock ? 2 : 0)
                }
                .hdrAnimation(Motion.standard, value: window.isEmphasizingLock)
                .reportsCanvasFoot(\.capsule, gap: Space.s4, name: "capsule")
                .padding(.bottom, Space.s4 + lift)
                .accessibilityElement(children: .contain)
            }
            .transition(.opacity)
        }
    }
}

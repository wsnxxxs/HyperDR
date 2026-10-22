import SwiftUI
import HyperDRDesign

/// The export history (M3 §9): the exports of the photo on the canvas, newest
/// first. Each can be restored (its settings become the current ones, one
/// undo step), shown in Finder or saved again.
struct ExportHistorySheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var sheetWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.export.isInFlight {
                InspectorNotice(Text("history.lockedNote"), style: .info)
                    .padding(.horizontal, Space.s5).padding(.top, Space.s3)
            }
            ExportTransferNotice(model: model)
                .padding(.horizontal, Space.s5).padding(.top, Space.s3)
            if model.exportVersions.isEmpty { empty } else { list }
            Divider()
            footer
        }
        .frame(width: 660)
        .frame(minHeight: 360, maxHeight: 620)
        .background(Color.hdr.surfacePanel)
        .background(WindowReader { sheetWindow = $0 })
        .task { model.refreshExportMetadata() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("history.title").font(Font.hdr.title).foregroundStyle(Color.hdr.inkStrong)
            // No "0 versions": an empty record is told by the empty state below.
            Text(model.exportVersions.isEmpty ? (model.document?.name ?? "")
                 : "\(model.document?.name ?? "") · \(AppStrings.format("history.versions %@", locale: locale, model.exportVersions.count.formatted(.number.locale(locale))))")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s4)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.exportVersions) { version in
                    row(version)
                        .padding(.horizontal, Space.s5)
                    Divider()
                }
            }
        }
    }

    private func row(_ version: ExportVersion) -> some View {
        let saving = model.exportSaveStates[version.id] == .saving
        let thumbnail = model.versionThumbnails[version.id] ?? .loading
        var tags: [HDRTag] = []
        if version.matchesCurrent { tags.append(HDRTag(Text("history.matches"), tint: .accent)) }
        if version.saved != nil { tags.append(HDRTag(Text("history.saved"), systemImage: "checkmark", tint: .success)) }
        let plan = HistoryRowPlan(model: model, version: version, saving: saving)
        let secondary: RowAction
        if version.saved != nil {
            secondary = RowAction(title: Text("export.save.showInFinder"), systemImage: "folder",
                                  isEnabled: plan.canShowInFinder,
                                  disabledReason: ExportRevealHelp.unavailable) {
                ExportFlow.showInFinder(model: model, version: version.id)
            }
        } else {
            secondary = RowAction(title: Text(saving ? "export.save.saving" : "export.save.saveAs"),
                                  isEnabled: plan.canSaveAs,
                                  disabledReason: version.fileAvailable ? nil : Text("history.fileMissing.help")) {
                ExportFlow.saveAs(model: model, version: version.id, choosePlace: ExportSavePanel.chooser(on: sheetWindow))
            }
        }
        return ExportHistoryRow(
            thumbnail: thumbnail.content(), number: version.number, fileName: version.fileName, tags: tags,
            meta: Text(verbatim: ExportPresentation.historyMeta(version, locale: locale)),
            note: version.fallbackReason.map { Text(verbatim: ExportPresentation.fallbackNote($0, model: model, locale: locale)) },
            extraNote: version.fileAvailable ? nil : Text("history.fileMissing"),
            primary: RowAction(title: Text("history.restore"),
                               isEnabled: plan.canRestore) {
                model.restore(version.id)
            },
            secondary: secondary,
            dragSource: ExportTransfer.dragSource(model: model, version: version.id, thumbnail: thumbnail, name: version.fileName),
            trailingAccessory: AnyView(ExportShareButton(model: model, version: version.id, thumbnail: thumbnail,
                                                     name: version.saved?.fileName ?? version.fileName)))
        .contextMenu { menu(version, saving: saving, thumbnail: thumbnail) }
        // Read lazily, once the row is on screen; it asks again if the model
        // let the picture go from its small cache.
        .task(id: model.versionThumbnails[version.id] == nil) {
            if model.versionThumbnails[version.id] == nil { _ = model.versionThumbnail(version.id) }
        }
    }

    /// What the file can be made to do, before the settings (M3 §9, parity batch 7 §1.4).
    @ViewBuilder private func menu(_ version: ExportVersion, saving: Bool, thumbnail: ThumbnailState) -> some View {
        let plan = HistoryRowPlan(model: model, version: version, saving: saving)
        if version.saved != nil {
            Button("export.save.showInFinder") { ExportFlow.showInFinder(model: model, version: version.id) }
                .disabled(!plan.canShowInFinder)
        }
        Button("export.save.saveAs") {
            ExportFlow.saveAs(model: model, version: version.id, choosePlace: ExportSavePanel.chooser(on: sheetWindow))
        }
        .disabled(!plan.canSaveAs)
        if let item = model.transferItem(for: version.id) {
            ShareLink(item: item, preview: SharePreview(Text(verbatim: item.fileName))) { Text("history.share") }
        } else {
            Button("history.share") {}.disabled(true)
        }
        Divider()
        Button("history.restore") { model.restore(version.id) }
            .disabled(!plan.canRestore)
    }

    private var empty: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 34, weight: .light)).foregroundStyle(Color.hdr.inkDisabled)
            Text("history.empty.title").font(Font.hdr.heading).foregroundStyle(Color.hdr.inkStrong)
            Text("history.empty.message")
                .font(Font.hdr.control).foregroundStyle(Color.hdr.inkMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Space.s6)
    }

    private var footer: some View {
        HStack {
            Text("history.footer").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            Spacer(minLength: Space.s3)
            Button("export.action.done") { dismiss() }
                .buttonStyle(.hdrPrimary).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
    }
}

/// What can be done with one row of the history right now; the row and its
/// context menu both read it, so they never disagree.
struct HistoryRowPlan: Equatable {
    /// Only a saved version has a place to show, and only while this session
    /// still holds the authority to reveal it.
    let canShowInFinder: Bool
    let canSaveAs: Bool
    /// Drag out and share: any version whose retained file is still there.
    let canTransfer: Bool
    let canRestore: Bool
    let hasFileMissingNote: Bool

    @MainActor init(model: EditorModel, version: ExportVersion, saving: Bool) {
        canShowInFinder = version.saved != nil && ExportFlow.canShowInFinder(model: model, version: version.id)
        canSaveAs = !saving && version.fileAvailable
        canTransfer = model.transferItem(for: version.id) != nil
        canRestore = !version.matchesCurrent && !model.isEditingLocked
        hasFileMissingNote = !version.fileAvailable
    }
}

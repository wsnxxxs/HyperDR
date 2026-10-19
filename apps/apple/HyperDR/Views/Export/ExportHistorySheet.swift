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
        var tags: [HDRTag] = []
        if version.matchesCurrent { tags.append(HDRTag(Text("history.matches"), tint: .accent)) }
        if version.saved != nil { tags.append(HDRTag(Text("history.saved"), systemImage: "checkmark", tint: .success)) }
        let secondary: RowAction
        if version.saved != nil {
            secondary = RowAction(title: Text("export.save.showInFinder"), systemImage: "folder") {
                ExportFlow.showInFinder(model: model, version: version.id)
            }
        } else {
            secondary = RowAction(title: Text(saving ? "export.save.saving" : "export.save.saveAs"), isEnabled: !saving) {
                ExportFlow.saveAs(model: model, version: version.id, choosePlace: ExportSavePanel.chooser(on: sheetWindow))
            }
        }
        return ExportHistoryRow(
            thumbnail: nil, number: version.number, fileName: version.fileName, tags: tags,
            meta: Text(verbatim: ExportPresentation.historyMeta(version, locale: locale)),
            note: version.fallbackReason.map { Text(verbatim: ExportPresentation.fallbackNote($0, model: model, locale: locale)) },
            primary: RowAction(title: Text("history.restore"),
                               isEnabled: !version.matchesCurrent && !model.isEditingLocked) {
                model.restore(version.id)
            },
            secondary: secondary)
        .contextMenu {
            Button("export.save.saveAs") {
                ExportFlow.saveAs(model: model, version: version.id, choosePlace: ExportSavePanel.chooser(on: sheetWindow))
            }
        }
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

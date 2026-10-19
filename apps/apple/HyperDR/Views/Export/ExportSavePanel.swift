import AppKit
import UniformTypeIdentifiers

/// The system save panel, on the window that asks: the name and place of
/// the file an export is going to make. Cancel calls back with nil and
/// nothing else happens (M3 §4).
@MainActor enum ExportSavePanel {
    typealias Chooser = (_ suggestedName: String, _ type: UTType, _ completion: @escaping (URL?) -> Void) -> Void

    static func chooser(on window: NSWindow?) -> Chooser {
        { name, type, completion in present(on: window, name: name, type: type, completion: completion) }
    }

    static func present(on window: NSWindow?, name: String, type: UTType, completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        let finish: (NSApplication.ModalResponse) -> Void = { completion($0 == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
}

/// Starts an export the way the preferences say: a save panel first in
/// "ask each time", straight away for a fixed folder. Cancelling the panel
/// does not reach the model, so it can make no job and no version.
@MainActor enum ExportFlow {
    static func begin(model: EditorModel, choosePlace: ExportSavePanel.Chooser) {
        // The model hands out one token for the photo and edits as they are
        // now; a panel answered after the photo changed gets nothing started.
        guard let token = model.prepareExport() else { return }
        if model.preferences.value.saveMode == .folder {
            model.startExport(destination: nil, token: token)
            return
        }
        choosePlace(model.suggestedFileName, model.exportContentType) { url in
            guard let url else { return }
            model.startExport(destination: url, token: token)
        }
    }

    /// Saves an earlier version to a place the user picks.
    static func saveAs(model: EditorModel, version: String, choosePlace: ExportSavePanel.Chooser) {
        guard let item = model.exportVersions.first(where: { $0.id == version }) else { return }
        let type = UTType(filenameExtension: (item.fileName as NSString).pathExtension) ?? model.exportContentType
        choosePlace(item.fileName, type) { url in
            guard let url else { return }
            model.saveExport(version, destination: url)
        }
    }

    /// Shows the file in Finder: the saved copy when this run knows where it
    /// is, else the version's own file.
    static func showInFinder(model: EditorModel, version: String) {
        if let url = model.exportVersions.first(where: { $0.id == version })?.saved?.url
            ?? (model.export.result?.export == version ? model.export.result?.saved?.url : nil) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        Task {
            if let url = await model.exportFileURL(version) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

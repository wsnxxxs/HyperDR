import SwiftUI
import UniformTypeIdentifiers

/// Edit ▸ Paste on the editor window (M3 §13): files copied in Finder open
/// like dropped ones; the clipboard holding only picture data cannot be
/// opened, and the canvas says so in place of a dialog.
@MainActor enum PasteImport {
    static let types: [UTType] = [.fileURL, .image]

    static func handle(_ providers: [NSItemProvider], model: EditorModel) {
        let hasFile = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        let hasImage = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard hasFile || hasImage else { return }
        Task {
            let files = await PhotoDropDelegate.urls(from: providers.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
            interpret(urls: files.urls, hasImageData: hasImage && !hasFile, model: model)
        }
    }

    /// What the clipboard's contents mean for the model: open the first
    /// openable file; for files that cannot be opened, the same alert a drop
    /// gives; for picture data alone, the hint.
    static func interpret(urls: [URL], hasImageData: Bool, model: EditorModel) {
        if urls.isEmpty { model.pasteFiles([], containsImageData: hasImageData); return }
        if urls.contains(where: model.canOpen) { model.pasteFiles(urls, containsImageData: false) }
        else { model.open(urls) }
    }
}

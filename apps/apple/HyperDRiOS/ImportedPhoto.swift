import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// The photo being edited, as a file of our own (p7-2b §3.3). The library
/// hands the original over as a file (`.current` keeps HEIC, DNG and gain
/// maps as they are) and Files inside its security scope; either way it is
/// copied into `tmp/Imported/<uuid>/`, so its bytes never pass through memory
/// and Render can open it again later (another development, a full-size
/// region) without a security scope.
struct ImportedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            ImportedPhoto(url: try copy(received.file))
        }
    }

    static var root: URL { FileManager.default.temporaryDirectory.appending(path: "Imported", directoryHint: .isDirectory) }

    /// Copies a file from Files, inside its security scope.
    static func copyFromFiles(_ url: URL) throws -> ImportedPhoto {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return ImportedPhoto(url: try copy(url))
    }

    private static func copy(_ file: URL) throws -> URL {
        let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    /// Removes this copy.
    func discard() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Copies left by an earlier run.
    static func discardAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

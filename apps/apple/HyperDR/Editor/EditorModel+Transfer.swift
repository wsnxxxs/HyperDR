import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// One export version, as something another app can take: dragged out of the
/// history or shared. It holds no file URL; the copy is made when the system
/// asks for the data, in a folder of its own, so a Finder move can never take
/// the version's retained file out of the history.
struct ExportTransferItem: Transferable {
    let version: String
    /// What the receiver calls the file: the name it was saved under, else the
    /// export's own name.
    let fileName: String
    let stage: @Sendable () async throws -> URL

    /// The file's own type, from its extension; nil for one nothing knows.
    var contentType: UTType? { Self.contentType(forFileName: fileName) }

    static func contentType(forFileName name: String) -> UTType? {
        switch (name as NSString).pathExtension.lowercased() {
        case "heic", "heif": .heic
        case "jpg", "jpeg": .jpeg
        case "tif", "tiff": .tiff
        case "avif": avif
        default: nil
        }
    }

    private static let avif = UTType("public.avif") ?? UTType(filenameExtension: "avif") ?? .image

    /// One representation per kind of file, so a receiver that asks for
    /// `public.heic` (Photos, some share services) gets the file, and Finder
    /// learns its name before the drop. A file of any other type goes out as
    /// a plain image.
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .heic) { try await $0.send() }
            .suggestedFileName { $0.fileName }
            .exportingCondition { $0.contentType == .heic }
        FileRepresentation(exportedContentType: .jpeg) { try await $0.send() }
            .suggestedFileName { $0.fileName }
            .exportingCondition { $0.contentType == .jpeg }
        FileRepresentation(exportedContentType: .tiff) { try await $0.send() }
            .suggestedFileName { $0.fileName }
            .exportingCondition { $0.contentType == .tiff }
        FileRepresentation(exportedContentType: avif) { try await $0.send() }
            .suggestedFileName { $0.fileName }
            .exportingCondition { $0.contentType == avif }
        FileRepresentation(exportedContentType: .image) { try await $0.send() }
            .suggestedFileName { $0.fileName }
    }

    private func send() async throws -> SentTransferredFile {
        SentTransferredFile(try await stage(), allowAccessingOriginalFile: false)
    }
}

extension EditorModel {
    /// Nil when the version's file is gone (then it cannot be dragged or
    /// shared) or the photo is.
    func transferItem(for version: String) -> ExportTransferItem? {
        let listed = exportVersions.first { $0.id == version }
        if let listed, !listed.fileAvailable { return nil }
        let result = export.result?.export == version ? export.result : nil
        guard let name = (listed?.result ?? result).map({ $0.saved?.fileName ?? $0.fileName }) else { return nil }
        // The copy is of this photo's version, whatever is open by the time
        // the receiver asks for it.
        guard let photo else { return nil }
        return ExportTransferItem(version: version, fileName: name) { [weak self] in
            guard let self else { throw UserFacingError(code: "source_missing") }
            return try await self.stageTransfer(version, fileName: name, photo: photo)
        }
    }

    private func stageTransfer(_ version: String, fileName: String, photo: EditorPhoto) async throws -> URL {
        do {
            let url = try await services.transferFile(photo, export: version, fileName: fileName)
            if self.photo == photo { export.transferFailure = nil }
            return url
        } catch {
            // Another photo is open by now: its panel has no use for this.
            if self.photo == photo { reportTransferFailure(version: version, fileName: fileName, error: UserFacingError.service(error)) }
            throw error
        }
    }

    func reportTransferFailure(version: String, fileName: String, error: UserFacingError) {
        export.transferFailure = TransferFailure(version: version, fileName: fileName, error: error)
    }
}

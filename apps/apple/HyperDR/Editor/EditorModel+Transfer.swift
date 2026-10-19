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

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try await item.stage(), allowAccessingOriginalFile: false)
        }
    }
}

extension EditorModel {
    /// Nil when the version's file is gone (then it cannot be dragged or
    /// shared) or the photo is.
    func transferItem(for version: String) -> ExportTransferItem? {
        guard photo != nil else { return nil }
        let listed = exportVersions.first { $0.id == version }
        if let listed, !listed.fileAvailable { return nil }
        let result = export.result?.export == version ? export.result : nil
        guard let name = listed.map({ $0.saved?.fileName ?? $0.fileName }) ?? result?.fileName else { return nil }
        return ExportTransferItem(version: version, fileName: name) { [weak self] in
            guard let self else { throw UserFacingError(code: "source_missing") }
            return try await self.stageTransfer(version, fileName: name)
        }
    }

    private func stageTransfer(_ version: String, fileName: String) async throws -> URL {
        guard let photo else { throw UserFacingError(code: "source_missing") }
        do {
            let url = try await services.transferFile(photo, export: version, fileName: fileName)
            export.transferFailure = nil
            return url
        } catch {
            reportTransferFailure(version: version, fileName: fileName, error: UserFacingError.service(error))
            throw error
        }
    }

    func reportTransferFailure(version: String, fileName: String, error: UserFacingError) {
        export.transferFailure = TransferFailure(version: version, fileName: fileName, error: error)
    }
}

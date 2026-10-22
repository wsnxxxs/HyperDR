import Foundation
import HyperDREngine
import Photos

public struct ExportLibrarySource: Sendable, Codable, Equatable {
    public let assetIdentifier: String?
    public init(assetIdentifier: String?) { self.assetIdentifier = assetIdentifier }
}
public struct SavedAsset: Sendable, Codable, Equatable {
    public let identifier: String
    public let mode: LibrarySaveMode
    public let canRestoreRecipe: Bool
    public init(identifier: String, mode: LibrarySaveMode, canRestoreRecipe: Bool) {
        self.identifier = identifier; self.mode = mode; self.canRestoreRecipe = canRestoreRecipe
    }
}
public protocol PhotoLibrarySaving: Sendable {
    func save(file: URL, snapshot: ResolvedExportSnapshot, source: ExportLibrarySource,
              mode: LibrarySaveMode) async throws -> SavedAsset
}
/// P7-3e entry and Fake seam. A new photo is added with
/// `PHAssetCreationRequest`, which needs only add-only access; replacing the
/// original (`PHContentEditingOutput`) still waits for Photos Lab.
public actor PhotoLibrarySaver: PhotoLibrarySaving {
    public static let verifiedModes: Set<LibrarySaveMode> = [.newPhoto]
    public init() {}
    public func save(file: URL, snapshot: ResolvedExportSnapshot, source: ExportLibrarySource,
                     mode: LibrarySaveMode) async throws -> SavedAsset {
        guard Self.verifiedModes.contains(mode) else {
            throw HyperDRError(code: "photos_not_verified", message: "Photo library saving has not been verified")
        }
        return try await addPhoto(file)
    }

    /// Adds a written export to the library as a new photo, asking for
    /// add-only access the first time. The file is copied; it stays in place.
    public func addPhoto(_ file: URL) async throws -> SavedAsset {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw HyperDRError(code: "photos_permission_denied", message: "Photo library access was not granted")
        }
        let created = Created()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = file.lastPathComponent
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: file, options: options)
                created.identifier = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw HyperDRError(code: "photos_save_failed", message: "The photo library did not accept the file",
                               messageDetail: String(describing: error))
        }
        return SavedAsset(identifier: created.identifier ?? "", mode: .newPhoto, canRestoreRecipe: false)
    }

    /// The new asset's identifier, set inside the change block.
    private final class Created: @unchecked Sendable {
        var identifier: String?
    }
}

import Foundation
import HyperDREngine

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
/// P7-3e entry and Fake seam. Photos Lab must establish supported modes before
/// this performs any library transaction or asks for library permission.
public actor PhotoLibrarySaver: PhotoLibrarySaving {
    public static let verifiedModes: Set<LibrarySaveMode> = []
    public init() {}
    public func save(file: URL, snapshot: ResolvedExportSnapshot, source: ExportLibrarySource,
                     mode: LibrarySaveMode) async throws -> SavedAsset {
        throw HyperDRError(code: "photos_not_verified", message: "Photo library saving has not been verified")
    }
}

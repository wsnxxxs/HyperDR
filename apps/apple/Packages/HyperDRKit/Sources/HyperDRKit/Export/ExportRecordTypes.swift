import Foundation
import HyperDREngine

/// A version's identity in the history: `ResolvedExportSnapshot.exportKey()`.
public struct ExportKey: Sendable, Codable, Equatable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The frame of a version written before recipe exports, as its record keeps
/// it: no temporary paths or PNG payload in history. Recipe exports keep their
/// frame in `RecipeExportSnapshot.frame`.
public struct ExportFrameRecord: Sendable, Codable, Equatable {
    public let spec: [String: JSONValue]
    public let overlaySHA256: String?
}

public struct SavedMark: Sendable, Codable, Equatable {
    public let fileName: String
    /// Last directory display name at save time, never a path.
    /// Missing in older records: consumers show their localized unknown label.
    public let folderDisplayName: String?
    public let savedAt: Date
    public init(fileName: String, folderDisplayName: String?, savedAt: Date = Date()) {
        self.fileName = fileName; self.folderDisplayName = folderDisplayName; self.savedAt = savedAt
    }
}

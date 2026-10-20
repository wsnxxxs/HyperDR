import Foundation
import HyperDREngine
import HyperDRRender

public enum RecipeExportError: Error, Sendable, Equatable {
    case busy, invalidSnapshot, sourceChanged, missingLUT, missingModel, invalidStripes
    case memoryExceeded(required: Int, available: Int?)
    case planBlocked([String])
    case verificationFailed(String)
}
public enum RecipeExportStage: String, Sendable, Codable {
    case preparing, model, developing, rendering, encoding, verifying, publishing, delivering
}
public struct RecipeExportProgress: Sendable {
    public let stage: RecipeExportStage
    public let completedRows: Int?
    public let totalRows: Int?
    public init(stage: RecipeExportStage, completedRows: Int? = nil, totalRows: Int? = nil) {
        self.stage = stage; self.completedRows = completedRows; self.totalRows = totalRows
    }
}
public struct RecipeExportResult: Sendable {
    public let record: ExportRecord
    public let resolved: ResolvedExportSnapshot
    /// The retained, verified file. Use SessionStore.stageExportForTransfer for sharing.
    public let file: URL
    public let saved: SavedExport?
    /// A delivery failure leaves record/file available for another save attempt.
    public let deliveryError: HyperDRError?
    public init(record: ExportRecord, resolved: ResolvedExportSnapshot, file: URL,
                saved: SavedExport? = nil, deliveryError: HyperDRError? = nil) {
        self.record = record; self.resolved = resolved; self.file = file
        self.saved = saved; self.deliveryError = deliveryError
    }
}

extension ExportRecord {
    /// Public construction for platform service Fakes; no legacy options needed.
    public init(id: ExportID, name: String, byteCount: Int64, createdAt: Date = Date(),
                resolved: ResolvedExportSnapshot, reportJSON: Data = Data(), sequence: Int = 1) throws {
        self.init(id: id, name: name, byteCount: byteCount, createdAt: createdAt,
                  sourceDigest: resolved.snapshot.source.sha256, options: [:], reportJSON: reportJSON,
                  sequence: sequence, key: try resolved.exportKey(), frame: nil,
                  recipeSnapshot: resolved.snapshot, resolvedSnapshot: resolved)
    }
}

/// All platforms use the same service. Keep its Task to cancel the entire operation.
/// Select a Mac file destination before calling; nil retains a verified version for
/// iOS fileExporter / ShareLink. Photos saving remains disabled until Photos Lab.
public protocol RecipeExportServicing: Sendable {
    func export(session: SessionID, snapshot: RecipeExportSnapshot,
                request: ExportPlanRequest, lut: ColorLUT?, destination: URL?,
                progress: @escaping @Sendable (RecipeExportProgress) -> Void) async throws -> RecipeExportResult
}

import Foundation
import HyperDREngine
import HyperDRRender

public enum RecipeExportError: Error, Sendable, Equatable {
    case busy, invalidSnapshot, sourceChanged, missingLUT, missingModel, invalidStripes
    case memoryExceeded(ExportBlockReason)
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
    /// Encoding pulls Render synchronously on the row path. Label this stage
    /// “Rendering and encoding”; rows describe this pass, not overall completion.
    public let includesRendering: Bool
    /// One-based sequential replay pass; nil outside the row writer.
    public let rowPass: Int?
    /// How many sequential passes the row writer makes over the rows (gain
    /// extrema, base, gain); nil when unknown or outside the row writer.
    public let rowPasses: Int?
    /// Once every row is written, checking and saving the file are one
    /// “Finishing up”, not stages of their own.
    public var stageMessage: ExportMessage {
        .init(key: "export.stage." + (isFinishing && stage != .delivering ? "finishing"
            : includesRendering ? "renderingEncoding" : stage.rawValue))
    }
    /// The whole export's completion, 0...1, so one bar fills once instead of
    /// once per pass: the rows (every pass of the row writer, or the stripes
    /// rendered before a whole-plane encode) take it to `rowsShare`, checking
    /// and saving the file the rest. Nil while the photo is still being read.
    /// Stateless: a caller keeps the largest value it has shown.
    public var fraction: Double? {
        switch stage {
        case .preparing, .model, .developing: return nil
        case .rendering, .encoding:
            guard let done = completedRows, let total = totalRows, total > 0 else {
                // A whole-plane encode follows all of its rendered stripes.
                return stage == .encoding && !includesRendering ? Self.wholePlaneRenderShare : nil
            }
            let rows = min(1, max(0, Double(done) / Double(total)))
            guard let pass = rowPass else { return Self.wholePlaneRenderShare * rows }
            let passes = max(pass, rowPasses ?? pass)
            return Self.rowsShare * (Double(pass - 1) + rows) / Double(passes)
        case .verifying: return Self.rowsShare
        case .publishing: return 0.95
        case .delivering: return 0.98
        }
    }
    /// Every row is written: what is left is checking and saving the file
    /// (the row writer checks its file before it returns).
    public var isFinishing: Bool {
        switch stage {
        case .verifying, .publishing, .delivering: return true
        case .encoding:
            guard let pass = rowPass, let passes = rowPasses, let total = totalRows else { return false }
            return pass >= passes && completedRows == total
        case .preparing, .model, .developing, .rendering: return false
        }
    }
    static let rowsShare = 0.9
    static let wholePlaneRenderShare = 0.6
    public init(stage: RecipeExportStage, completedRows: Int? = nil, totalRows: Int? = nil, includesRendering: Bool = false,
                rowPass: Int? = nil, rowPasses: Int? = nil) {
        self.includesRendering = includesRendering; self.rowPass = rowPass; self.rowPasses = rowPasses
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
    public var size: ExportPixelSize { .init(width: resolved.width, height: resolved.height) }
    public var byteCount: Int64 { record.byteCount }
    private var evidence: RecipeExportReport? { try? JSONDecoder().decode(RecipeExportReport.self, from: record.reportJSON) }
    private var package: PackageReport? {
        evidence?.packageJSON.flatMap { try? JSONDecoder().decode(PackageReport.self, from: $0) }
    }
    /// Written headroom, from the package metadata (system reader for ImageIO).
    public var peakStops: Double? {
        guard resolved.ceilingStops != nil else { return nil }
        return package?.gain?.alternateHeadroom ?? evidence?.system.verifiedHeadroomStops.max()
    }
    public var verified: Bool {
        guard let evidence else { return false }
        if let package { return package.verified }
        if evidence.imageIO != nil { return true }
        // SDR Adaptive has no gain-write report. Its native probe and the
        // independent system readback are the two successful readers.
        return resolved.encoding == .adaptive && resolved.ceilingStops == nil
            && evidence.firstReaderJSON != nil
            && evidence.system.width == resolved.width && evidence.system.height == resolved.height
            && !evidence.system.auxiliaryGain && !evidence.system.hdrReadable
    }
    private let operationElapsed: Duration?
    /// Includes publication and delivery when returned by the live service.
    public var elapsed: Duration { operationElapsed ?? .seconds(evidence?.stageSeconds.values.reduce(0, +) ?? 0) }
    public var ceilingApplied: (edit: Double, written: Double)? {
        guard let before = resolved.rangeBeforeCeiling, let after = resolved.rangeAfterCeiling,
              before.isFinite, after.isFinite, before > after + 1e-4 else { return nil }
        return (Double(before), Double(after))
    }
    public init(record: ExportRecord, resolved: ResolvedExportSnapshot, file: URL,
                saved: SavedExport? = nil, deliveryError: HyperDRError? = nil, elapsed: Duration? = nil) {
        self.record = record; self.resolved = resolved; self.file = file
        self.saved = saved; self.deliveryError = deliveryError; self.operationElapsed = elapsed
    }
}

extension ExportRecord {
    /// Public construction for platform service Fakes; no legacy options needed.
    public init(id: ExportID, name: String, byteCount: Int64, createdAt: Date = Date(),
                resolved: ResolvedExportSnapshot, reportJSON: Data = Data(), sequence: Int = 1,
                saved: SavedMark? = nil, fileAvailable: Bool = true) throws {
        self.init(id: id, name: name, byteCount: byteCount, createdAt: createdAt,
                  sourceDigest: resolved.snapshot.source.sha256, options: [:], reportJSON: reportJSON,
                  sequence: sequence, key: try resolved.exportKey(), frame: nil,
                  recipeSnapshot: resolved.snapshot, resolvedSnapshot: resolved, saved: saved, fileAvailable: fileAvailable)
    }
}

/// All platforms use the same service. Keep its Task to cancel the entire operation.
/// Select a Mac file destination before calling; nil retains a verified version for
/// iOS fileExporter / ShareLink. Photos saving remains disabled until Photos Lab.
public protocol RecipeExportServicing: Sendable {
    /// Read after a failed export; nil if it did not fail memory admission.
    var lastMemoryDiagnostic: ExportMemoryDiagnostic? { get async }
    func export(session: SessionID, snapshot: RecipeExportSnapshot,
                request: ExportPlanRequest, lut: ColorLUT?, destination: URL?,
                progress: @escaping @Sendable (RecipeExportProgress) -> Void) async throws -> RecipeExportResult
}

extension RecipeExportServicing {
    public var lastMemoryDiagnostic: ExportMemoryDiagnostic? { get async { nil } }
}

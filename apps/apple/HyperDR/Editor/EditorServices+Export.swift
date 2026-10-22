import CoreGraphics
import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRecipe
import HyperDRRender

/// Existing preview-only test doubles can use the unsupported service defaults.
/// Live and Fake implement the complete M3 surface below/alongside their records.
extension EditorServices {
    func startExport(_ photo: EditorPhoto, job: RecipeExportJob, destination: URL?) async throws -> EditorExportTicket { throw UserFacingError(code: "engine_unavailable") }
    /// A revision made from the photo's URL, the same for every call.
    func sourceRevision(_ photo: EditorPhoto) async throws -> RecipeSourceRevision {
        RecipeSourceRevision(sha256: photo.url.path, byteCount: photo.byteCount, modificationDate: .distantPast)
    }
    func exportThumbnail(_ photo: EditorPhoto, version: String) async -> CGImage? { nil }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> { AsyncStream { $0.finish() } }
    func cancelAllExports() async {}
    func hasExportActivity() async -> Bool { false }
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem] { [] }
    func exportTimingHistory() async -> [ExportTimingSample] { [] }
    func suggestedFileName(_ photo: EditorPhoto, encoding: String) async throws -> String {
        photo.url.deletingPathExtension().lastPathComponent + "-hyperdr." + EditorModel.fileExtension(encoding)
    }
    func validateDestination(_ url: URL, expectedExtension: String) async throws {
        guard url.isFileURL, url.pathExtension.lowercased() == expectedExtension else { throw UserFacingError(code: "invalid_options") }
    }
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation { throw UserFacingError(code: "export_folder_unset") }
    func transferFile(_ photo: EditorPhoto, export: String, fileName: String?) async throws -> URL { throw UserFacingError(code: "source_missing") }
    func relink(_ photo: EditorPhoto, to url: URL) async throws -> EditorPhoto { throw UserFacingError(code: "source_different") }
    func exportFolder() async -> ExportFolder { ExportFolder() }
    func setExportFolder(_ url: URL) async throws -> ExportFolder { throw UserFacingError(code: "export_folder_unwritable") }
    func encodingCapabilities() async throws -> EditorCapabilities {
        EditorCapabilities(encodings: Dictionary(uniqueKeysWithValues: Preferences.encodings.map { ($0, .init(available: true, reason: "")) }), main8: true, main10: true)
    }
    func aboutInformation() async -> AboutInformation { AboutInformation() }
    func diagnostics() async -> String { "" }
    func lutEntries() async -> [LUTItem] { [] }
    func importLUT(_ url: URL) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func removeLUT(_ id: String) async throws { throw UserFacingError(code: "lut_invalid") }
    func recipeLUT(_ photo: EditorPhoto, contentHash: String) async throws -> ColorLUT { throw UserFacingError(code: "lut_invalid") }
}

extension ExportChoices {
    /// The panel's settings a recipe export asked for: an ISO gain-map JPEG
    /// written as SDR (HDR off) still restores, and matches, as one.
    nonisolated init(_ resolved: ResolvedExportSnapshot) {
        if case .custom(let format) = resolved.selection { self.init(format) }
        else { self.init(CustomExportFormat(encoding: resolved.encoding, gamut: resolved.gamut, quality: resolved.quality)) }
    }
}

extension ExportHistoryItem {
    nonisolated init(_ record: ExportRecord) {
        if let resolved = record.resolvedSnapshot { self.init(record, resolved: resolved) }
        else { self.init(legacy: record) }
    }

    /// A version from before recipe exports: its report and panel settings.
    private nonisolated init(legacy record: ExportRecord) {
        let report = (try? JSONSerialization.jsonObject(with: record.reportJSON)) as? [String: Any]
        let file = (report?["files"] as? [[String: Any]])?.first(where: { $0["success"] as? Bool == true }) ?? [:]
        var options = ExportChoices()
        if case .string(let id)? = record.options["encoding"] { options.encoding = id }
        if case .string(let id)? = record.options["outputGamut"] { options.outputGamut = id }
        if case .number(let value)? = record.options["quality"] { options.quality = value }
        let width = file["width"] as? Int ?? 0, height = file["height"] as? Int ?? 0
        let size = width > 0 && height > 0 ? PixelSize(width: width, height: height) : nil
        let stages = ["decode_ms", "process_ms", "encode_ms", "verify_ms"].map { (file[$0] as? Double ?? 0) / 1000 }
        let result = ExportResult(export: record.id.rawValue, fileName: record.name, byteCount: record.byteCount,
            pixelSize: size, headroomStops: file["headroom_stops"] as? Double,
            selfVerified: file["self_verified"] as? Bool ?? false, elapsed: .seconds(stages.reduce(0,+)),
            warnings: file["decode_degradation_reasons"] as? [String] ?? [], saved: Self.saved(record))
        let version = ExportVersion(number: record.sequence, createdAt: record.createdAt, encodingID: options.encoding,
            modelName: (file["model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hasFrame: record.frame != nil, fileAvailable: record.fileAvailable, result: result)
        let ext = URL(fileURLWithPath: file["input"] as? String ?? "").pathExtension
        let raw = FakeEditorServices.formatLabel(for: URL(fileURLWithPath: "x." + ext)) == "RAW"
        let timing = size.map { ExportTimingSample(kind: .init(isRAW: raw, encoding: options.encoding,
            isAI: record.options["useModel"] == .bool(true), hasFrame: record.frame != nil, verifies: result.selfVerified),
            pixels: Double($0.width) * Double($0.height), stages: stages) }
        self.init(version: version, options: options, timing: timing)
    }

    /// A recipe export (P7-3b): what it was made from and what it resolved to.
    private nonisolated init(_ record: ExportRecord, resolved: ResolvedExportSnapshot) {
        let report = try? JSONDecoder().decode(RecipeExportReport.self, from: record.reportJSON)
        let seconds = report?.stageSeconds ?? [:]
        func time(_ stages: RecipeExportStage...) -> Double { stages.reduce(0) { $0 + (seconds[$1.rawValue] ?? 0) } }
        let stages = [time(.preparing, .model, .developing), time(.rendering), time(.encoding) + (seconds["read"] ?? 0), time(.verifying)]
        let size = PixelSize(width: resolved.width, height: resolved.height)
        let options = ExportChoices(resolved)
        let result = ExportResult(export: record.id.rawValue, fileName: record.name, byteCount: record.byteCount,
            pixelSize: size, headroomStops: resolved.ceilingStops, selfVerified: true,
            elapsed: .seconds(stages.reduce(0, +)), saved: Self.saved(record))
        let snapshot = record.recipeSnapshot ?? resolved.snapshot
        let version = ExportVersion(number: record.sequence, createdAt: record.createdAt, encodingID: options.encoding,
            gamut: resolved.gamut, modelName: resolved.modelIdentity, hasFrame: snapshot.frame != nil,
            fileAvailable: record.fileAvailable, result: result)
        let raw = snapshot.recipe.inputDomain == .rawEDR
        let timing = ExportTimingSample(kind: .init(isRAW: raw, encoding: options.encoding, isAI: resolved.modelIdentity != nil,
            hasFrame: snapshot.frame != nil, verifies: true), pixels: Double(size.width) * Double(size.height), stages: stages)
        self.init(version: version, recipeSnapshot: snapshot, resolved: resolved, options: options, timing: timing)
    }

    private nonisolated static func saved(_ record: ExportRecord) -> SavedLocation? {
        record.saved.map { SavedLocation(fileName: $0.fileName, folderLabel: SavedLocation.label(displayName: $0.folderDisplayName)) }
    }
}

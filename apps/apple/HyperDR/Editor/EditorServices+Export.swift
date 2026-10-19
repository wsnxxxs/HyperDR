import Foundation
import HyperDREngine
import HyperDRKit

/// Existing preview-only test doubles can use the unsupported service defaults.
/// Live and Fake implement the complete M3 surface below/alongside their records.
extension EditorServices {
    func startExport(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?, destination: URL?) async throws -> EditorExportTicket { throw UserFacingError(code: "engine_unavailable") }
    func exportEvents(_ job: String) -> AsyncStream<EditorExportEvent> { AsyncStream { $0.finish() } }
    func cancelAllExports() async {}
    func hasExportActivity() async -> Bool { false }
    func commandLine(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> [String] { [] }
    func exportKey(_ photo: EditorPhoto, options: EditOptions, frame: ExportFrame?) async throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(options.values), as: UTF8.self)
    }
    func exports(for photo: EditorPhoto) async throws -> [ExportHistoryItem] { [] }
    func exportTimingHistory() async -> [ExportTimingSample] { [] }
    func suggestedFileName(_ photo: EditorPhoto, options: EditOptions) async throws -> String {
        photo.url.deletingPathExtension().lastPathComponent + "-hyperdr." + EditorModel.fileExtension(options["encoding"]?.editorString ?? "adaptive")
    }
    func validateDestination(_ url: URL, expectedExtension: String) async throws {
        guard url.isFileURL, url.pathExtension.lowercased() == expectedExtension else { throw UserFacingError(code: "invalid_options") }
    }
    func saveExport(_ photo: EditorPhoto, export: String, destination: URL?) async throws -> SavedLocation { throw UserFacingError(code: "export_folder_unset") }
    func exportFolder() async -> ExportFolder { ExportFolder() }
    func setExportFolder(_ url: URL) async throws -> ExportFolder { throw UserFacingError(code: "export_folder_unwritable") }
    func encodingCapabilities() async throws -> EditorCapabilities {
        EditorCapabilities(encodings: Dictionary(uniqueKeysWithValues: Preferences.encodings.map { ($0, .init(available: true, reason: "")) }), main8: true, main10: true)
    }
    func diagnostics() async -> String { "" }
    func exportFileURL(_ photo: EditorPhoto, export: String) async throws -> URL { throw UserFacingError(code: "session_expired") }
    func lutEntries() async -> [LUTItem] { [] }
    func importLUT(_ url: URL) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func applyLUT(_ id: String, to photo: EditorPhoto) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func updateLUT(_ id: String, input: LUTColorSpace, output: LUTColorSpace) async throws -> LUTItem { throw UserFacingError(code: "lut_invalid") }
    func removeLUT(_ id: String) async throws { throw UserFacingError(code: "lut_invalid") }
}

extension ExportHistoryItem {
    nonisolated init(_ record: ExportRecord) {
        let report = (try? JSONSerialization.jsonObject(with: record.reportJSON)) as? [String: Any]
        let file = (report?["files"] as? [[String: Any]])?.first(where: { $0["success"] as? Bool == true }) ?? [:]
        let options = EditSnapshot(EditOptions(record.options), aiMode: record.options["useModel"] == .bool(true) ? .optimized : .manual)
        let width = file["width"] as? Int ?? 0, height = file["height"] as? Int ?? 0
        let size = width > 0 && height > 0 ? PixelSize(width: width, height: height) : nil
        let warnings = file["decode_degradation_reasons"] as? [String] ?? []
        let stages = ["decode_ms", "process_ms", "encode_ms", "verify_ms"].map { (file[$0] as? Double ?? 0) / 1000 }
        let result = ExportResult(export: record.id.rawValue, fileName: record.name, byteCount: record.byteCount,
            pixelSize: size, headroomStops: file["headroom_stops"] as? Double,
            selfVerified: file["self_verified"] as? Bool ?? false, elapsed: .seconds(stages.reduce(0,+)),
            warnings: warnings, saved: record.saved.map { SavedLocation(fileName: $0.fileName, folderLabel: $0.folderLabel) })
        version = ExportVersion(number: record.sequence, createdAt: record.createdAt, encodingID: options.encoding,
            modelName: (file["model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            fallbackNote: (file["model_fallback_reason"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hasFrame: record.frame != nil, result: result)
        key = record.key.rawValue; self.options = options
        // Report input_domain alone cannot distinguish RAW from other scene inputs;
        // input suffix uses the same source categories as the engine's discovery.
        let ext = URL(fileURLWithPath: file["input"] as? String ?? "").pathExtension
        let raw = FakeEditorServices.formatLabel(for: URL(fileURLWithPath: "x." + ext)) == "RAW"
        timing = size.map { ExportTimingSample(kind: .init(isRAW: raw, encoding: options.encoding,
            isAI: options.aiMode == .optimized, hasFrame: record.frame != nil, verifies: result.selfVerified),
            pixels: Double($0.width) * Double($0.height), stages: stages) }
    }
}

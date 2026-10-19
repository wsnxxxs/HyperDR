import Foundation
import Observation

nonisolated struct Preferences: Equatable {
    enum SaveMode: String { case ask, folder }
    enum InitialView: String { case edited, original }
    var histogramRGB = false
    var highlightZebra = false
    var shadowZebra = false
    var initialView: InitialView = .edited
    var rememberOutput = true
    var saveMode: SaveMode = .ask
    var output: [String: String] = [:]
    static let key = "HyperDRPreferencesV1"
    static let encodings = ["adaptive", "iso-gainmap-jpeg", "pq", "hlg", "avif-pq", "avif-hlg", "sdr-jpeg", "sdr-tiff"]
    static func load(from defaults: UserDefaults) -> Self {
        guard let d = defaults.dictionary(forKey: key) else { return Self() }
        var result = Self()
        result.histogramRGB = d["histogramRGB"] as? Bool ?? false
        result.highlightZebra = d["highlightZebra"] as? Bool ?? false
        result.shadowZebra = d["shadowZebra"] as? Bool ?? false
        result.rememberOutput = d["rememberOutput"] as? Bool ?? true
        result.initialView = InitialView(rawValue: d["initialView"] as? String ?? "") ?? .edited
        result.saveMode = SaveMode(rawValue: d["saveMode"] as? String ?? "") ?? .ask
        if let output = d["output"] as? [String: String] {
            for (key, value) in output where valid(key: key, value: value) { result.output[key] = value }
        }
        return result
    }
    static func valid(key: String, value: String) -> Bool {
        switch key {
        case "encoding": encodings.contains(value)
        case "colorGamut": ["srgb", "p3", "rec2020"].contains(value)
        case "outputGamut": ["auto", "srgb", "p3"].contains(value)
        case "clampSrgb": ["true", "false"].contains(value)
        case "modelId": !value.isEmpty && value.count < 200
        default: false
        }
    }
    func save(to defaults: UserDefaults) {
        defaults.set(["histogramRGB": histogramRGB, "highlightZebra": highlightZebra,
            "shadowZebra": shadowZebra, "rememberOutput": rememberOutput,
            "initialView": initialView.rawValue, "saveMode": saveMode.rawValue,
            "output": output.filter { Self.valid(key: $0.key, value: $0.value) }], forKey: Self.key)
    }
}
nonisolated struct ExportFolder: Equatable, Sendable {
    var label = ""
    var ready = false
    var target: ExportFolderTarget? = nil
}
/// App-owned opaque authority. Views use only ExportFolder's label and ready.
@MainActor final class ExportFolderTarget: Equatable {
    private let action: (EditorPhoto, String) async throws -> SavedLocation
    init(save: @escaping (EditorPhoto, String) async throws -> SavedLocation) { action = save }
    func save(_ photo: EditorPhoto, export: String) async throws -> SavedLocation {
        try await action(photo, export)
    }
    nonisolated static func == (lhs: ExportFolderTarget, rhs: ExportFolderTarget) -> Bool { lhs === rhs }
}
@MainActor @Observable final class PreferencesState {
    var value: Preferences
    var exportFolder = ExportFolder()
    var diagnostics = ""
    var failure: UserFacingError?
    init(_ value: Preferences) { self.value = value }
}

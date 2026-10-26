import Foundation
import HyperDRRender
import Observation

nonisolated struct Preferences: Equatable {
    enum SaveMode: String { case ask, folder }
    enum InitialView: String { case edited, original }
    var rawDecoder: RAWDecoderPreference = .automatic
    var histogramRGB = false
    var highlightZebra = false
    var shadowZebra = false
    var initialView: InitialView = .edited
    var rememberOutput = true
    var saveMode: SaveMode = .ask
    var output: [String: String] = [:]
    static let key = "HyperDRPreferencesV1"
    static let encodings = ["adaptive", "iso-gainmap-jpeg", "pq", "hlg", "avif-pq", "avif-hlg", "sdr-jpeg", "sdr-tiff",
                            "sdr-dng", "hdr-tiff-16", "hdr-tiff-32", "hdr-dng"]
    /// A RAW 9 choice stored where this system has no RAW 9 (Settings does
    /// not list it there) reads as Automatic.
    static func load(from defaults: UserDefaults, supportsRAW9: Bool = RenderEngine.systemSupportsRAW9) -> Self {
        var result = Self()
        result.rawDecoder = .load(from: defaults)
        if result.rawDecoder == .raw9, !supportsRAW9 { result.rawDecoder = .automatic }
        guard let d = defaults.dictionary(forKey: key) else { return result }
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
        case "outputGamut": ["auto", "srgb", "p3", "rec2020"].contains(value)
        case "tiffDepth": ["16", "32"].contains(value)
        case "modelId": !value.isEmpty && value.count < 200
        default: false
        }
    }
    func save(to defaults: UserDefaults) {
        rawDecoder.save(to: defaults)
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
    private let revealAction: () async throws -> Void
    private let action: (EditorPhoto, String) async throws -> SavedLocation
    init(reveal: @escaping () async throws -> Void = { throw UserFacingError(code: "export_folder_unset") },
         save: @escaping (EditorPhoto, String) async throws -> SavedLocation) {
        revealAction = reveal; action = save
    }
    func reveal() async throws { try await revealAction() }
    func save(_ photo: EditorPhoto, export: String) async throws -> SavedLocation {
        try await action(photo, export)
    }
    nonisolated static func == (lhs: ExportFolderTarget, rhs: ExportFolderTarget) -> Bool { lhs === rhs }
}
@MainActor @Observable final class PreferencesState {
    var value: Preferences
    var exportFolder = ExportFolder()
    var diagnostics = ""
    var about = AboutInformation()
    var failure: UserFacingError?
    init(_ value: Preferences) { self.value = value }
}

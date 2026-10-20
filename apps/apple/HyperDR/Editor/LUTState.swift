import Foundation
import Observation
import HyperDRKit

nonisolated enum LUTColorSpace: String, CaseIterable, Sendable {
    case srgb, p3, rec709, hlg, pq
    case slog3SGamut3Cine = "slog3-sgamut3cine"
}
nonisolated struct LUTItem: Identifiable, Equatable, Sendable {
    var id: String; var name: String; var input: LUTColorSpace; var output: LUTColorSpace
    var byteCount: UInt64 = 0
}
@MainActor @Observable final class LUTState {
    var library: [LUTItem] = []
    var selection: LUTItem?
    var isEnabled = true
    var spaceIssueKey: String?
    var isBusy = false
    var importBlocker: String? { importBlockerKey }
    var importBlockerKey: String?
    var failures: [UserFacingError] = []
}
nonisolated struct EditorCapabilities: Sendable {
    struct Encoding: Sendable { var available: Bool; var reason: String }
    var encodings: [String: Encoding]
    var main8: Bool
    var main10: Bool
    var encoderReason: String?
    func availability(isHDR: Bool) -> [String: String?] {
        var result: [String: String?] = [:]
        for id in Preferences.encodings {
            let facts = ExportEncodingCapabilities(main8: main8, main10: main10,
                probeFailed: encoderReason == "hevc_probe_failed",
                unavailableEncodings: Set(Preferences.encodings.compactMap { id in
                    encodings[id]?.available == true ? nil : ExportEncoding(rawValue: id)
                }))
            let reason = ExportEncoding(rawValue: id).flatMap {
                ExportPlanner.availability(of: $0,
                    source: ExportSource(domain: isHDR ? .hdr : .sdr, pixelSize: .init(width: 1, height: 1)),
                    capabilities: facts, edit: .init(peakStops: 1))
            }
            let key = reason.map { "err.server." + $0.code }
            result[id] = .some(key)
        }
        return result
    }
}

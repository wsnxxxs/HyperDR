import Foundation
import Observation
import HyperDRKit

/// A library LUT's input or output space: Kit's, named apart from
/// HyperDRRender's `LUTSpace`, which most editor files also import. (This
/// file imports Kit alone, so `LUTSpace` here is Kit's.)
typealias LUTColorSpace = LUTSpace

extension LUTSpace {
    /// The spaces as the library's menus list them: display, HDR, then the
    /// cameras' Log encodings, which only a RAW photo's look can take as input.
    var family: LUTSpaceFamily {
        switch self {
        case .srgb, .p3, .rec709, .rec2020: .display
        case .hlg, .pq: .hdr
        default: .log
        }
    }
}

nonisolated enum LUTSpaceFamily: CaseIterable, Sendable {
    case display, hdr, log
    var titleKey: String {
        switch self {
        case .display: "lut.space.family.display"
        case .hdr: "lut.space.family.hdr"
        case .log: "lut.space.family.log"
        }
    }
}
nonisolated struct LUTItem: Identifiable, Equatable, Sendable {
    var id: String; var name: String; var input: LUTColorSpace; var output: LUTColorSpace
    var byteCount: UInt64 = 0
}
@MainActor @Observable final class LUTState {
    var library: [LUTItem] = []
    var selection: LUTItem?
    var isEnabled = true
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
    /// The encoder facts Kit plans with (K6).
    var exportFacts: ExportEncodingCapabilities {
        ExportEncodingCapabilities(main8: main8, main10: main10,
            probeFailed: encoderReason == "hevc_probe_failed",
            unavailableEncodings: Set(Preferences.encodings.compactMap { id in
                encodings[id]?.available == true ? nil : ExportEncoding(rawValue: id)
            }))
    }
    func availability(isHDR: Bool) -> [String: String?] {
        var result: [String: String?] = [:]
        let facts = exportFacts
        for id in Preferences.encodings {
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

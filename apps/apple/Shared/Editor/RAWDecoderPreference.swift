import Foundation

/// The developer for newly opened RAW photos. A saved recipe always keeps its
/// recorded decoder, including nil for a legacy recipe's system default.
/// `libRAW` unpacks every camera with LibRaw and develops the DNG it writes,
/// so colour comes from one generic matrix path rather than Apple's per-camera
/// tuning; the recipe records the converter and reopens through it.
nonisolated enum RAWDecoderPreference: String, CaseIterable, Equatable, Sendable {
    case automatic, raw8, raw9, libRAW = "libraw"

    static let key = "HyperDRRAWDecoderPreferenceV1"

    var generation: Int? {
        switch self {
        case .automatic, .libRAW: nil
        case .raw8: 8
        case .raw9: 9
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .automatic
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.key)
    }
}

/// Only new photos use this default; saved recipes keep their calibration.
nonisolated enum RAWBrightnessPreference {
    static let key = "HyperDRRAWCameraBrightnessV1"
    static func load(from defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}

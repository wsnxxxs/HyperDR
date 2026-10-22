import Foundation

/// A sentence part a view composes. Kit's only sentences are an export's
/// stages (`RecipeExportProgress.stageMessage`); the plan itself is typed.
public enum ExportMessageArgument: Sendable, Hashable {
    /// Already-formatted text (a number, a byte count).
    case text(String)
    /// Another catalogue key, resolved before it is substituted.
    case key(String)
    /// A stop count, written by `ExportPlanText.stops` ("+2.4").
    case stops(Double)
    /// A pixel count, written by `ExportPlanText.pixels`.
    case pixels(Int)
}

public struct ExportMessage: Sendable, Hashable {
    public let key: String
    public let arguments: [ExportMessageArgument]

    /// Resolve from Kit's catalogue, independent of the host app's bundle.
    public func localized(locale: Locale = .current) -> String {
        let language = locale.identifier.hasPrefix("zh") ? "zh-Hans" : "en"
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? Bundle.module
        func text(_ key: String) -> String { bundle.localizedString(forKey: key, value: nil, table: nil) }
        let values: [String] = arguments.map {
            switch $0 {
            case .text(let value): value
            case .key(let key): text(key)
            case .stops(let value): ExportPlanText.stops(value)
            case .pixels(let value): ExportPlanText.pixels(value)
            }
        }
        return String(format: text(key), locale: locale, arguments: values)
    }

    public init(key: String, arguments: [ExportMessageArgument] = []) {
        self.key = key
        self.arguments = arguments
    }
}

/// How the plan's numbers are written. Locale-independent on purpose: the app
/// formats the same values with the user's locale elsewhere, and this is the one
/// place a plan's own sentences (a stop count, a byte count) are spelled out.
public enum ExportPlanText {
    /// "+2.4", "+3": a stop count with its sign, at most one decimal.
    public static func stops(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        let digits = rounded == rounded.rounded() ? 0 : 1
        return String(format: "%+.\(digits)f", rounded)
    }

    public static func pixels(_ value: Int) -> String { "\(value)" }

    /// "3.1 GB", "400 MB": decimal units, enough for a sentence.
    public static func bytes(_ value: Int) -> String {
        let gigabytes = Double(value) / 1_000_000_000
        if gigabytes >= 1 { return String(format: "%.1f GB", gigabytes) }
        if value < 1_000_000 { return "< 1 MB" }
        return String(format: "%.0f MB", Double(value) / 1_000_000)
    }
}


// Plan facts for logs and tests. The words for notices and reasons are the
// hosts' (`Shared/Export/ExportReasonText`, HyperDRDesign's catalogue).
extension ExportBlockReason {
    public var code: String {
        switch self {
        case .memory: "export_memory_exceeded"
        case .photosNotAvailable(.notVerified): "photos_not_verified"
        case .photosNotAvailable: "photos_permission_denied"
        case .encoderUnavailable(_, .probeFailed): "hevc_probe_failed"
        case .encoderUnavailable(_, .main10Unavailable): "hevc_main10_unavailable"
        case .encoderUnavailable: "hevc_unavailable"
        case .hdrOff: "hdrOff"
        case .unsupportedPair: "unsupported_format"
        }
    }
    public var pixelSize: ExportPixelSize? {
        if case .memory(_, _, let size, _) = self { size } else { nil }
    }
}

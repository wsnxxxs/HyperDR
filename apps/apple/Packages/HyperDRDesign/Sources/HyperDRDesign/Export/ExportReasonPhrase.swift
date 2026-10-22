import Foundation

/// The words for an export plan's notices and the reasons it cannot run,
/// shared by the Mac and iOS apps (p7-3c-export §1.3 G). Plain values in,
/// text out: `Shared/Export/ExportReasonText` maps Kit's typed reasons onto
/// these, so this package does not depend on Kit.
public enum ExportReasonPhrase: Hashable, Sendable {
    /// The output's peak is held at `stops` ("+3"), by a destination or by
    /// the format.
    case ceiling(stops: String, byFormat: Bool)
    case socialAspect
    case sdrVersion
    case alphaOnBlack
    /// Memory: what the export needs and what is available ("3.1 GB").
    case memory(needed: String, available: String)
    case photosNotVerified
    case photosPermission
    case photosFileSource
    case photosFramed
    case photosAddOnly
    case photosLibraryAccess
    case hevcUnavailable
    case hevcMain10Unavailable
    case hevcProbeFailed
    case hdrOff
    case unsupportedPair
    /// The short reason on an option that cannot be chosen yet.
    case notYetAvailable
    /// The action that sets the largest long edge that fits, in pixels.
    case useLongEdge(Int)

    public func text(locale: Locale = .current) -> String {
        switch self {
        case .ceiling(let stops, false):
            return String(format: DesignStrings.string("export.reason.ceiling %@", bundle: .module, locale: locale), stops)
        case .ceiling(let stops, true):
            return String(format: DesignStrings.string("export.reason.ceilingFormat %@", bundle: .module, locale: locale), stops)
        case .socialAspect: return DesignStrings.string("export.reason.socialAspect", bundle: .module, locale: locale)
        case .sdrVersion: return DesignStrings.string("export.reason.sdrVersion", bundle: .module, locale: locale)
        case .alphaOnBlack: return DesignStrings.string("export.reason.alphaOnBlack", bundle: .module, locale: locale)
        case .memory(let needed, let available):
            return String(format: DesignStrings.string("export.reason.memory %@ %@", bundle: .module, locale: locale),
                          needed, available)
        case .photosNotVerified: return DesignStrings.string("export.reason.photosNotVerified", bundle: .module, locale: locale)
        case .photosPermission: return DesignStrings.string("export.reason.photosPermission", bundle: .module, locale: locale)
        case .photosFileSource: return DesignStrings.string("export.reason.photosFileSource", bundle: .module, locale: locale)
        case .photosFramed: return DesignStrings.string("export.reason.photosFramed", bundle: .module, locale: locale)
        case .photosAddOnly: return DesignStrings.string("export.reason.photosAddOnly", bundle: .module, locale: locale)
        case .photosLibraryAccess: return DesignStrings.string("export.reason.photosLibraryAccess", bundle: .module, locale: locale)
        case .hevcUnavailable: return DesignStrings.string("export.reason.hevcUnavailable", bundle: .module, locale: locale)
        case .hevcMain10Unavailable: return DesignStrings.string("export.reason.hevcMain10Unavailable", bundle: .module, locale: locale)
        case .hevcProbeFailed: return DesignStrings.string("export.reason.hevcProbeFailed", bundle: .module, locale: locale)
        case .hdrOff: return DesignStrings.string("export.reason.hdrOff", bundle: .module, locale: locale)
        case .unsupportedPair: return DesignStrings.string("export.reason.unsupportedPair", bundle: .module, locale: locale)
        case .notYetAvailable: return DesignStrings.string("export.reason.notYetAvailable", bundle: .module, locale: locale)
        case .useLongEdge(let edge):
            return String(format: DesignStrings.string("export.reason.useLongEdge %@", bundle: .module, locale: locale),
                          String(edge))
        }
    }
}

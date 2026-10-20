import Foundation
import HyperDRDesign
import HyperDRKit

/// Kit's typed plan facts in the shared words of HyperDRDesign
/// (`ExportReasonPhrase`), for the Mac and iOS hosts. Kit names what is said;
/// this says which words; the design package's catalogue holds them.
extension ExportNotice {
    nonisolated var phrase: ExportReasonPhrase {
        switch self {
        case .ceiling(let stops, .destination): .ceiling(stops: ExportPlanText.stops(stops), byFormat: false)
        case .ceiling(let stops, .format): .ceiling(stops: ExportPlanText.stops(stops), byFormat: true)
        case .socialAspect: .socialAspect
        case .sdrVersion: .sdrVersion
        case .alphaOnBlack: .alphaOnBlack
        }
    }
}

extension PhotosUnavailableReason {
    nonisolated var phrase: ExportReasonPhrase {
        switch self {
        case .notVerified: .photosNotVerified
        case .permissionDenied: .photosPermission
        case .fileSource: .photosFileSource
        case .framed: .photosFramed
        case .addOnly: .photosAddOnly
        case .selectedAssetUnavailable: .photosLibraryAccess
        }
    }
}

extension ExportBlockReason {
    /// The sentence that says why the export cannot run.
    nonisolated var phrase: ExportReasonPhrase {
        switch self {
        case .memory(let needed, let available, _, _):
            .memory(needed: ExportPlanText.bytes(needed), available: ExportPlanText.bytes(available))
        case .photosNotAvailable(let reason): reason.phrase
        case .encoderUnavailable(_, .main8Unavailable): .hevcUnavailable
        case .encoderUnavailable(_, .main10Unavailable): .hevcMain10Unavailable
        case .encoderUnavailable(_, .probeFailed): .hevcProbeFailed
        case .hdrOff: .hdrOff
        case .unsupportedPair: .unsupportedPair
        }
    }

    /// The short reason on a destination that cannot be chosen: only the
    /// Photos destination before its saving is verified (p7-3c-export §1.3 F).
    nonisolated var destinationShortPhrase: ExportReasonPhrase? {
        if case .photosNotAvailable(.notVerified) = self { return .notYetAvailable }
        return nil
    }

    /// The largest long edge that fits, when memory is the reason and a
    /// smaller size would.
    nonisolated var suggestedLongEdge: Int? {
        if case .memory(_, _, _, let edge) = self { return edge }
        return nil
    }
}

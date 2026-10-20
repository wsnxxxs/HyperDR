import Foundation
import HyperDREngine

public enum ExportNoticeScope: Sendable, Hashable {
    case destination(ExportDestination), format(ExportEncoding)
}
public enum ExportNotice: Sendable, Hashable {
    case ceiling(stops: Double, scope: ExportNoticeScope)
    case socialAspect, sdrVersion, alphaOnWhite
}
public enum PhotosUnavailableReason: Sendable, Hashable {
    case notVerified, permissionDenied, fileSource, framed, addOnly, selectedAssetUnavailable
}
public enum HEVCReason: Sendable, Hashable {
    case main8Unavailable, main10Unavailable, probeFailed
}
public enum ExportBlockReason: Sendable, Hashable {
    case memory(needed: Int, available: Int, size: ExportPixelSize, maxLongEdge: Int?)
    case photosNotAvailable(PhotosUnavailableReason)
    case encoderUnavailable(ExportEncoding, HEVCReason)
    case hdrOff(ExportEncoding)
    case unsupportedPair
}

/// Facts from the host's encoder probe. A false probe failure means the profile
/// booleans are authoritative. Defaults preserve callers that do not probe yet.
public struct ExportEncodingCapabilities: Sendable, Hashable {
    public var main8: Bool
    public var main10: Bool
    public var probeFailed: Bool
    public var unavailableEncodings: Set<ExportEncoding>
    public init(main8: Bool = true, main10: Bool = true, probeFailed: Bool = false,
                unavailableEncodings: Set<ExportEncoding> = []) {
        self.main8 = main8; self.main10 = main10; self.probeFailed = probeFailed
        self.unavailableEncodings = unavailableEncodings
    }
    public init(_ capabilities: Capabilities) {
        self.init(main8: capabilities.encoder?.main8 ?? false,
                  main10: capabilities.encoder?.main10 ?? false,
                  probeFailed: capabilities.encoder == nil || capabilities.encoder?.reason == "hevc_probe_failed",
                  unavailableEncodings: Set(capabilities.encodings.filter { !$0.available }.compactMap { ExportEncoding(rawValue: $0.id) }))
    }
}
extension ExportPlanner {
    public static func availability(of encoding: ExportEncoding, source: ExportSource,
                                    capabilities: ExportEncodingCapabilities,
                                    edit: ExportEditFacts) -> ExportBlockReason? {
        if encoding.isBT2100 && !edit.hdrEnabled { return .hdrOff(encoding) }
        // Adaptive's SDR fallback uses ImageIO main8, while an HDR rendition
        // requires a main10 base. AVIF/JPEG/TIFF do not use HEVC profiles.
        let needs10 = encoding == .pq || encoding == .hlg || (encoding == .adaptive && edit.hdrEnabled && source.isHDRRendition)
        let needsHEVC = encoding == .adaptive || encoding == .pq || encoding == .hlg
        if needsHEVC && capabilities.probeFailed { return .encoderUnavailable(encoding, .probeFailed) }
        if needsHEVC && !(needs10 ? capabilities.main10 : capabilities.main8) {
            return .encoderUnavailable(encoding, needs10 ? .main10Unavailable : .main8Unavailable)
        }
        if capabilities.unavailableEncodings.contains(encoding) {
            return .encoderUnavailable(encoding, .main8Unavailable)
        }
        return nil
    }
}

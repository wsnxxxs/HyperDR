import Foundation
import HyperDREngine

public struct PreviewRegion: Sendable, Hashable {
    public let left, top, width, height: Int
    public let center: Bool

    public init(left: Int, top: Int, width: Int, height: Int, center: Bool = false) {
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.center = center
    }
}

public struct PreviewRequest: Sendable, Hashable {
    public enum Purpose: Sendable, Hashable {
        case reference
        case edit
    }

    public var session: SessionID
    public var options: EditOptions
    public var maxEdge: Int
    public var region: PreviewRegion?
    /// Only classifies events; it is not part of the cache key.
    public var purpose: Purpose
    /// Caller identity for terminal events; excluded from render/cache identity.
    public var submissionID: UUID?

    public init(session: SessionID, options: EditOptions, maxEdge: Int,
                region: PreviewRegion? = nil, purpose: Purpose = .edit, submissionID: UUID? = nil) {
        self.session = session
        self.options = options
        self.maxEdge = maxEdge
        self.region = region
        self.purpose = purpose
        self.submissionID = submissionID
    }
}

public struct PreviewTimings: Sendable, Hashable {
    public let queued, gateWait, engine: Duration

    public init(queued: Duration = .zero, gateWait: Duration = .zero, engine: Duration = .zero) {
        self.queued = queued
        self.gateWait = gateWait
        self.engine = engine
    }
}

public struct PreviewResult: Sendable {
    public let request: PreviewRequest
    public let frame: PreviewFrame
    /// Digest of the source used to render this frame, including cache hits.
    public let sourceDigest: String
    public let fromCache: Bool
    public let timings: PreviewTimings
}

public enum PreviewEvent: Sendable {
    case started(PreviewRequest)
    case finished(PreviewResult)
    case failed(PreviewRequest, HyperDRError)
    case superseded(PreviewRequest)
}

extension PreviewFrame {
    /// Page-aligned native memory retained by the cache, plus metadata bytes.
    var previewCacheBytes: Int {
        base.allocationBytes + gain.allocationBytes + metadataJSON.count
    }
}

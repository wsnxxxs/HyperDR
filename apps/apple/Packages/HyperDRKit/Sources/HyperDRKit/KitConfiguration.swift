import Foundation

/// Process-wide service-layer locations and limits.
public struct KitConfiguration: Sendable {
    public var supportDirectory: URL
    public var cacheDirectory: URL
    /// Idle expiry for sessions without retained exports; launch restore still
    /// uses this interval even when export history retains a session.
    public var sessionTTL: Duration
    public var exportHistoryLimit: Int
    public var previewCacheEntries: Int
    public var previewCacheBytes: Int
    public var previewMaxEdge: Int
    public var previewTimeout: Duration
    public var jobTimeout: Duration
    public var maxJobLogCharacters: Int
    public var rawDecodeSlots: Int

    public init(
        supportDirectory: URL = Self.defaultSupportDirectory,
        cacheDirectory: URL = Self.defaultCacheDirectory,
        sessionTTL: Duration = .seconds(24 * 60 * 60),
        exportHistoryLimit: Int = 20,
        previewCacheEntries: Int = 2,
        previewCacheBytes: Int = 256 << 20,
        previewMaxEdge: Int = 2048,
        previewTimeout: Duration = .seconds(180),
        jobTimeout: Duration = .seconds(3600),
        maxJobLogCharacters: Int = 200_000,
        rawDecodeSlots: Int = 1
    ) {
        self.supportDirectory = supportDirectory
        self.cacheDirectory = cacheDirectory
        self.sessionTTL = sessionTTL
        self.exportHistoryLimit = max(1, exportHistoryLimit)
        self.previewCacheEntries = previewCacheEntries
        self.previewCacheBytes = previewCacheBytes
        self.previewMaxEdge = previewMaxEdge
        self.previewTimeout = previewTimeout
        self.jobTimeout = jobTimeout
        self.maxJobLogCharacters = maxJobLogCharacters
        self.rawDecodeSlots = rawDecodeSlots
    }

    public static var defaultSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HyperDR", isDirectory: true)
    }

    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("HyperDR", isDirectory: true)
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

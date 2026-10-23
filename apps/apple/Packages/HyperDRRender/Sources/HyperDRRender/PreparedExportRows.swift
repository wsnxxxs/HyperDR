import Foundation

/// Frozen export header and a synchronous, replayable ROI reader. Reads are
/// serialized on a private renderer's executor; no actor hop or semaphore is
/// used. The original RenderEngine can continue serving other work. Retain file
/// access for the reader's lifetime. Apple decoder caches may remain resident;
/// Render allocates only the requested ROI, its sampling halo and analysis.
public final class PreparedExportRows: Sendable {
    /// HEIC's native slab height. Callers may replay smaller arbitrary ranges.
    public static let maximumReadRows = 512
    /// Includes the two-native-texel sampling halo on each side. A downscale
    /// splits further rather than materializing a taller native-source crop.
    public static let maximumSourceTileSize = PixelSize(width:4096,height:516)
    /// Linear film exposure, its horizontal pass and the accumulated scatter.
    /// All three are RGBA float32 and overlap until the render command completes.
    public static let filmWorkspaceBytesPerPixel = 3 * 4 * MemoryLayout<Float>.stride
    public let report: ExportRenderReport
    private let readRows: @Sendable (Int,Int) throws -> ExportStripe

    init(report: ExportRenderReport, read: @escaping @Sendable (Int,Int) throws -> ExportStripe) {
        self.report = report
        readRows = read
    }

    /// Native output canvas coordinates, including frame rows. Requests can be
    /// replayed in any order. count must be at most maximumReadRows (512);
    /// use 256 for a smaller CPU row buffer. Task cancellation and source revision are checked.
    public func read(y: Int, count: Int) throws -> ExportStripe {
        try Task.checkCancellation()
        guard count > 0, count <= Self.maximumReadRows else { throw RenderError.invalidRegion }
        return try readRows(y,count)
    }
}

/// One queue owns all renderer state. checkIsolated makes assumeIsolated valid
/// when a synchronous package callback has entered this queue with sync.
final class ExportRowsExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label:"app.hyperdr.render",qos:.userInitiated)
    private let key = DispatchSpecificKey<UInt8>()
    init() { queue.setSpecific(key:key,value:1) }
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { autoreleasepool { job.runSynchronously(on:self.asUnownedSerialExecutor()) } }
    }
    func checkIsolated() { dispatchPrecondition(condition:.onQueue(queue)) }
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:key) != nil { return try body() }
        return try queue.sync { try autoreleasepool(invoking:body) }
    }
}

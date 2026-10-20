import Foundation

/// Frozen export header and a synchronous, replayable ROI reader. Reads are
/// serialized on a private renderer's executor; no actor hop or semaphore is
/// used. The original RenderEngine can continue serving other work. Retain file
/// access for the reader's lifetime. Apple decoder caches may remain resident;
/// Render allocates only the requested ROI, its sampling halo and analysis.
public final class PreparedExportRows: Sendable {
    public let report: ExportRenderReport
    private let readRows: @Sendable (Int,Int) throws -> ExportStripe

    init(report: ExportRenderReport, read: @escaping @Sendable (Int,Int) throws -> ExportStripe) {
        self.report = report
        readRows = read
    }

    /// Native output canvas coordinates, including frame rows. Requests can be
    /// replayed in any order. Keep count bounded (256 recommended) to retain
    /// stripe-sized memory. Task cancellation and source revision are checked.
    public func read(y: Int, count: Int) throws -> ExportStripe {
        try Task.checkCancellation()
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
        queue.async { job.runSynchronously(on:self.asUnownedSerialExecutor()) }
    }
    func checkIsolated() { dispatchPrecondition(condition:.onQueue(queue)) }
    func sync<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key:key) != nil { return try body() }
        return try queue.sync(execute:body)
    }
}

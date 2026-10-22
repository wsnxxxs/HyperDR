import Foundation
import MetricKit

/// Keeps what MetricKit delivers — crash, hang, CPU, disk-write and launch
/// diagnostics, and the daily metrics — as JSON under
/// Application Support/Diagnostics/MetricKit, for the diagnostics export.
/// The system delivers a crash's report at the next launch; nothing reaches
/// the developer unless the user sends the export.
nonisolated final class MetricsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsCollector()
    static var directory: URL { DiagnosticLog.directory.appending(path: "MetricKit", directoryHint: .isDirectory) }
    private static let keptDiagnostics = 20
    private static let keptMetrics = 14

    private let queue = DispatchQueue(label: "com.hyperdr.HyperDR.metrics", qos: .utility)

    /// Subscribes, and keeps the payloads delivered before this launch.
    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        didReceive(manager.pastDiagnosticPayloads)
        didReceive(manager.pastPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let kept = payloads.map(Payload.init)
        queue.async { for payload in kept { self.keep(payload, limit: Self.keptDiagnostics) } }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        let kept = payloads.map(Payload.init)
        queue.async { for payload in kept { self.keep(payload, limit: Self.keptMetrics) } }
    }

    /// What is kept of a payload, read on the delivering thread.
    private struct Payload: Sendable {
        let kind: String
        let json: Data
        let begin, end: Date
        /// "1 crash, 2 hang" for a diagnostic payload; nil for metrics.
        let summary: String?

        init(_ payload: MXDiagnosticPayload) {
            kind = "diagnostic"
            json = payload.jsonRepresentation()
            begin = payload.timeStampBegin
            end = payload.timeStampEnd
            let counts = [("crash", payload.crashDiagnostics?.count ?? 0),
                          ("hang", payload.hangDiagnostics?.count ?? 0),
                          ("CPU", payload.cpuExceptionDiagnostics?.count ?? 0),
                          ("disk write", payload.diskWriteExceptionDiagnostics?.count ?? 0),
                          ("launch", payload.appLaunchDiagnostics?.count ?? 0)]
                .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }.joined(separator: ", ")
            summary = counts.isEmpty ? "diagnostics" : counts
        }

        init(_ payload: MXMetricPayload) {
            kind = "metrics"
            json = payload.jsonRepresentation()
            begin = payload.timeStampBegin
            end = payload.timeStampEnd
            summary = nil
        }
    }

    private func keep(_ payload: Payload, limit: Int) {
        guard save(payload.json, kind: payload.kind, begin: payload.begin, end: payload.end, keep: limit),
              let summary = payload.summary else { return }
        DiagnosticLog.error("MetricKit", "System reported \(summary)")
    }

    /// Writes a payload once (named by its period) and drops the oldest of
    /// its kind beyond `keep`. False when it was already kept.
    private func save(_ json: Data, kind: String, begin: Date, end: Date, keep: Int) -> Bool {
        let manager = FileManager.default
        let stamp = DiagnosticLog.fileStamp
        let file = Self.directory.appending(path: "\(kind)-\(begin.formatted(stamp))-\(end.formatted(stamp)).json")
        guard !manager.fileExists(atPath: file.path) else { return false }
        do {
            try manager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try json.write(to: file, options: .atomic)
        } catch {
            return false
        }
        let kept = ((try? manager.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("\(kind)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in kept.dropLast(keep) { try? manager.removeItem(at: old) }
        return true
    }
}

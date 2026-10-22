import Foundation
import OSLog
import UIKit

/// The file a tester sends when something goes wrong: a zip of
/// `summary.txt` (app, device, system, memory, display), `current-run.log`
/// (this run's unified log under the app's subsystem, private values
/// redacted by the system), `launches/` (the last launches' lines,
/// `DiagnosticLog`) and `metrickit/` (`MetricsCollector`). No photos, no
/// file names.
enum DiagnosticsReport {
    /// Builds the zip in the temporary directory, replacing an earlier one.
    static func make() async throws -> URL {
        let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen
        let display = screen.map {
            String(format: "EDR headroom now %.2f×, up to %.2f×", $0.currentEDRHeadroom, $0.potentialEDRHeadroom)
        } ?? "no screen"
        return try await Task.detached(priority: .userInitiated) { try build(display: display) }.value
    }

    nonisolated private static func build(display: String) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try? manager.removeItem(at: root)
        let name = "HyperDR-Diagnostics-\(Date().formatted(DiagnosticLog.fileStamp))"
        let folder = root.appending(path: name, directoryHint: .isDirectory)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)

        DiagnosticLog.notice("App", "Diagnostics exported")
        DiagnosticLog.shared.flush()
        try summary(display: display).write(to: folder.appending(path: "summary.txt"), atomically: true, encoding: .utf8)
        try currentRun().write(to: folder.appending(path: "current-run.log"), atomically: true, encoding: .utf8)
        for (source, target) in [(DiagnosticLog.launches, "launches"), (MetricsCollector.directory, "metrickit")]
            where manager.fileExists(atPath: source.path) {
            try manager.copyItem(at: source, to: folder.appending(path: target, directoryHint: .isDirectory))
        }

        // The coordinator hands out a zip of the folder for the block's duration.
        var zipped: URL?
        var failure: (any Error)?
        var coordination: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zip in
            let target = root.appending(path: "\(name).zip")
            do {
                try manager.copyItem(at: zip, to: target)
                zipped = target
            } catch {
                failure = error
            }
        }
        if let error = coordination ?? failure { throw error }
        guard let zipped else { throw CocoaError(.fileWriteUnknown) }
        try? manager.removeItem(at: folder)
        return zipped
    }

    nonisolated private static func summary(display: String) -> String {
        let facts = DeviceFacts.current()
        let process = ProcessInfo.processInfo
        let thermal = switch process.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return """
        \(facts.app)
        Device: \(facts.model), \(String(format: "%.1f", facts.memoryGiB)) GB memory
        System: \(facts.system)
        Available to the app now: \(DeviceFacts.availableMemory)
        Thermal state: \(thermal); Low Power Mode: \(process.isLowPowerModeEnabled ? "on" : "off")
        Display: \(display)
        Languages: \(Locale.preferredLanguages.joined(separator: ", "))
        Launched: \(DiagnosticLog.shared.launchDate.formatted(.iso8601))
        Written: \(Date().formatted(.iso8601))

        current-run.log  this run's log (com.hyperdr.HyperDR)
        launches/        the last launches' lines, one file per launch
        metrickit/       crash, hang and resource reports, and daily metrics, from the system

        """
    }

    /// This process's entries under the app's subsystem since launch.
    nonisolated private static func currentRun() -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: DiagnosticLog.shared.launchDate),
                                               matching: NSPredicate(format: "subsystem == %@", DiagnosticLog.subsystem))
            let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            return entries.compactMap { $0 as? OSLogEntryLog }.map { entry in
                let level = switch entry.level {
                case .error: "E"
                case .fault: "F"
                case .debug: "d"
                case .info: "i"
                default: "-"
                }
                return "\(entry.date.formatted(stamp)) \(level) [\(entry.category)] \(entry.composedMessage)"
            }.joined(separator: "\n") + "\n"
        } catch {
            return "The system log could not be read: \(EditorLog.describe(error))\n"
        }
    }
}

import Foundation
import UIKit
import os

/// The app's diagnostic lines, kept across launches so a tester can send them
/// after the app quit or was stopped: each line goes to unified logging and to
/// this launch's file under Application Support/Diagnostics/Launches. The last
/// `keptLaunches` files stay, each up to `fileLimit` bytes, out of backups.
/// Lines name stages, sizes, formats and error kinds; never file names or
/// paths (`EditorLog.describe`).
nonisolated final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    static let subsystem = "com.hyperdr.HyperDR"
    static var directory: URL { .applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory) }
    static var launches: URL { directory.appending(path: "Launches", directoryHint: .isDirectory) }
    private static let keptLaunches = 5
    private static let fileLimit = 1 << 20

    let launchDate = Date()
    private let queue = DispatchQueue(label: "com.hyperdr.HyperDR.diagnostics", qos: .utility)
    /// The open file and how much went into it; touched on `queue` only.
    private var handle: FileHandle?
    private var written = 0

    private init() {
        queue.async { self.openFile() }
    }

    /// Opens this launch's file, routes the editing core's lines into it and
    /// notes what the system says about memory. Call once, at launch.
    @MainActor func start() {
        EditorLog.mirror { isError, line in DiagnosticLog.shared.append("Editor", isError, line) }
        Self.notice("App", "Launched \(DeviceFacts.current().line)")
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { _ in
            Self.error("App", "Memory warning; available to the app \(DeviceFacts.availableMemory)")
        }
    }

    static func notice(_ category: String, _ line: String) {
        Logger(subsystem: subsystem, category: category).notice("\(line, privacy: .public)")
        shared.append(category, false, line)
    }

    static func error(_ category: String, _ line: String) {
        Logger(subsystem: subsystem, category: category).error("\(line, privacy: .public)")
        shared.append(category, true, line)
    }

    /// Waits until every line logged so far is in the file.
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func append(_ category: String, _ isError: Bool, _ line: String) {
        let text = "\(Date().formatted(Self.timestamp)) \(isError ? "E" : "-") [\(category)] \(line)\n"
        queue.async { self.write(text) }
    }

    private func write(_ text: String) {
        guard let handle, written < Self.fileLimit else { return }
        var data = Data(text.utf8)
        if written + data.count >= Self.fileLimit { data = Data("… the rest of this launch is not kept\n".utf8) }
        do {
            try handle.write(contentsOf: data)
            written += data.count
        } catch {
            self.handle = nil
        }
    }

    private func openFile() {
        let manager = FileManager.default
        var directory = Self.directory
        do {
            try manager.createDirectory(at: Self.launches, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            return
        }
        // File names sort by launch time; keep room for this one.
        let old = ((try? manager.contentsOfDirectory(at: Self.launches, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in old.dropLast(Self.keptLaunches - 1) { try? manager.removeItem(at: file) }
        let file = Self.launches.appending(path: "\(launchDate.formatted(Self.fileStamp)).log")
        guard manager.createFile(atPath: file.path, contents: nil) else { return }
        handle = try? FileHandle(forWritingTo: file)
    }

    private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    /// "2026-10-23T101502Z": sortable, no characters a file name refuses.
    static let fileStamp = Date.ISO8601FormatStyle(timeSeparator: .omitted)
}

/// What a report says about the device the app runs on.
nonisolated struct DeviceFacts: Sendable {
    let app: String
    let system: String
    let model: String
    let memoryGiB: Double

    static func current() -> DeviceFacts {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var name = utsname()
        uname(&name)
        let machine = withUnsafeBytes(of: &name.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return DeviceFacts(app: "HyperDR \(version) (\(build))",
                           system: ProcessInfo.processInfo.operatingSystemVersionString,
                           model: simulated.map { "\($0) Simulator" } ?? machine,
                           memoryGiB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
    }

    /// "HyperDR 0.5.0 (1) · iPhone18,1 · Version 27.0 (Build 24A…) · 12.0 GB".
    var line: String {
        "\(app) · \(model) · \(system) · \(String(format: "%.1f", memoryGiB)) GB"
    }

    /// "1834 MiB": what the system would still give this process before
    /// stopping it. The Simulator reports none.
    static var availableMemory: String {
        let bytes = os_proc_available_memory()
        return bytes > 0 ? "\(bytes / 1_048_576) MiB" : "not reported"
    }
}

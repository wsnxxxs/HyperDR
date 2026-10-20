import Foundation
import Combine

enum LogLevel: String, Codable {
    case info, ok, warn, fail
}

struct LogEntry: Identifiable, Codable {
    var id = UUID()
    var time: Date
    var step: String
    var level: LogLevel
    var message: String
    var details: [String: JSONValue]
}

/// 结果日志：逐条显示在界面上，每加一条就整份重写 JSON，崩了也有记录。
@MainActor
final class LabLog: ObservableObject {
    @Published private(set) var entries: [LogEntry] = []
    let fileURL: URL
    private let startedAt = Date()
    private let environment: [String: JSONValue]

    init(directory: URL, environment: [String: JSONValue]) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("photos-lab-log-\(stamp).json")
        self.environment = environment
        save()
    }

    func add(_ step: String, _ level: LogLevel, _ message: String, _ details: [String: JSONValue] = [:]) {
        entries.append(LogEntry(time: Date(), step: step, level: level, message: message, details: details))
        save()
    }

    private func save() {
        struct File: Encodable {
            var app = "HyperDR Photos Lab"
            var startedAt: Date
            var environment: [String: JSONValue]
            var entries: [LogEntry]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(File(startedAt: startedAt, environment: environment, entries: entries)) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

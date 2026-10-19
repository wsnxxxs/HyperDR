import Foundation
import HyperDRKit

@main struct Parity {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard (5...6).contains(arguments.count) else {
            throw NSError(domain: "HyperDRKitParity", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Usage: HyperDRKitParity <input> <options.json> <workspace> <destination> [frame.json]"])
        }
        let workspace = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: workspace.appendingPathComponent("support"),
            cacheDirectory: workspace.appendingPathComponent("cache")))
        let photo = try await kit.sessions.open(URL(fileURLWithPath: arguments[1]))
        var options = try JSONDecoder().decode(EditOptions.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
        if let path = ProcessInfo.processInfo.environment["HYPERDR_PARITY_LUT"] {
            let entry = try await kit.luts.importLUT(URL(fileURLWithPath: path), into: photo.id)
            options.values["lutId"] = .string(entry.id.rawValue)
        }
        let frame = try arguments.count == 6 ? JSONDecoder().decode(ExportFrame.self,
            from: Data(contentsOf: URL(fileURLWithPath: arguments[5]))) : nil
        let diagnosticArgv = try await kit.jobs.commandLine(session: photo.id, options: options, frame: frame)
        let ticket = try await kit.jobs.start(session: photo.id, options: options, frame: frame)
        for await event in kit.jobs.events(ticket.job) {
            if case .finished(let result) = event {
                if let failure = result.failure { throw failure }
                guard result.result != nil else { throw NSError(domain: "HyperDRKitParity", code: 1) }
            }
        }
        let saved = try await kit.exportTarget.save(session: photo.id, export: ticket.export,
            oneOff: URL(fileURLWithPath: arguments[4], isDirectory: true))
        await kit.sessions.close(photo.id)
        let json = try JSONSerialization.data(withJSONObject: ["path": saved.url.path, "argv": ticket.argv, "diagnosticArgv": diagnosticArgv], options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}

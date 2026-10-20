import Foundation
import Darwin
import CoreGraphics
import ImageIO
import HyperDREngine
import Testing
import Synchronization
@testable import HyperDRKit

final class JobEnvironment: Sendable {
    let root: URL
    let configuration: KitConfiguration
    let sessions: SessionStore
    init(timeout: Duration = .seconds(30), historyLimit: Int = 20,
         openExportLeaf: @escaping SessionStore.OpenExportLeaf = { openat($0, $1, $2) },
         beforeThumbnailWrite: @escaping @Sendable (Int32) -> Void = { _ in }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-jobs-\(UUID())")
        configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache"), exportHistoryLimit: historyLimit, jobTimeout: timeout)
        let schema = try Engine.schema()
        sessions = SessionStore(configuration: configuration, formats: try InputFormats(schema: schema),
            decodeCacheMaxAge: 7 * 24 * 60 * 60, decodeCacheMaxBytes: 4 << 30, openExportLeaf: openExportLeaf, beforeThumbnailWrite: beforeThumbnailWrite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func photo(_ name: String = "photo.png") async throws -> PhotoSession {
        let source = root.appendingPathComponent(name)
        try Data([137,80,78,71,13,10,26,10] + [UInt8](repeating: 0, count: 64)).write(to: source)
        return try await sessions.open(source)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ExportTargetTests {
    @Test func rejectsWorkspaceAliasesAndNonDirectoriesWithoutLeavingAProbe() async throws {
        let env = try JobEnvironment()
        _ = try await env.photo()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        let alias = env.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: env.configuration.supportDirectory)
        for directory in [env.configuration.supportDirectory, alias,
                          env.configuration.supportDirectory.appendingPathComponent("sessions")] {
            #expect(await failureCode { _ = try await target.setFolder(directory) } == "export_folder_inside_workspace")
        }
        let file = env.root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        #expect(await failureCode { _ = try await target.setFolder(file) } == "export_folder_unwritable")
        _ = try await target.setFolder(env.root)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: env.root.path)).contains { $0.hasPrefix(".hyperdr-write-check") })
    }
    @Test func symlinkThenDotDotUsesFilesystemOrder() async throws {
        let env = try JobEnvironment()
        _ = try await env.photo()
        let nested = env.configuration.supportDirectory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let alias = env.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: nested)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        let path = URL(fileURLWithPath: alias.path + "/..")
        #expect(await failureCode { _ = try await target.setFolder(path) } == "export_folder_inside_workspace")
    }
}
private func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
private func failureCode(_ operation: () async throws -> Void) async -> String? {
    do { try await operation(); return nil } catch let error as HyperDRError { return error.code }
    catch { Issue.record("Unexpected error: \(error)"); return nil }
}

@Suite(.timeLimit(.minutes(1))) struct JobTests {
    @Test func disposingOnePendingVersionDoesNotUnpinAnother() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let a = try await env.sessions.prepareExport(photo.id, options: [:], key: ExportKey(rawValue: "fixture"))
        let b = try await env.sessions.prepareExport(photo.id, options: [:], key: ExportKey(rawValue: "fixture"))
        await env.sessions.close(photo.id)
        await env.sessions.discardExport(photo.id, export: a.id)
        #expect(await env.sessions.cleanupExpired(now: Date().addingTimeInterval(1_000_000)) == 0)
        #expect(FileManager.default.fileExists(atPath: b.directory.path))
        await env.sessions.discardExport(photo.id, export: b.id)
        #expect(await env.sessions.cleanupExpired(now: Date().addingTimeInterval(1_000_000)) == 1)
    }
}

extension ExportTargetTests {
    @Test func persistedRootFolderStillHasANonemptyPrivateLabel() async throws {
        let env = try JobEnvironment()
        _ = try await env.photo()
        // Restore an existing directory preference. This only reads root; it
        // never probes or creates a file in a system directory.
        let bookmark = try URL(fileURLWithPath: "/", isDirectory: true).bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try bookmark.write(to: env.configuration.supportDirectory.appendingPathComponent("export-folder.bookmark"))
        let restored = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        let folder = await restored.folder
        #expect(folder.ready)
        #expect(folder.label == "…/" + FileManager.default.displayName(atPath: "/"))
        #expect(folder.label != "/")
    }
}

/// Blocks only a native callback or detached copy thread, never the Swift
/// test executor. Tests release it after establishing cancellation or trimming.
private final class BlockingJobGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var waiting = false
    private var released = false
    private var timedOut = false
    var entered: Bool { condition.withLock { waiting } }
    var didTimeOut: Bool { condition.withLock { timedOut } }
    func waitForRelease() {
        condition.lock()
        defer { condition.unlock() }
        waiting = true
        let deadline = Date().addingTimeInterval(30)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; break }
        }
    }
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@Suite(.timeLimit(.minutes(1))) struct M3HistoryTests {
    private func publish(_ env: JobEnvironment, _ photo: PhotoSession) async throws -> ExportRecord {
        let version = try await env.sessions.prepareExport(photo.id, options: [:], key: ExportKey(rawValue: "fixture"))
        let file = version.directory.appendingPathComponent("photo.tif")
        try Data([1, 2, 3]).write(to: file)
        let report = ConvertReport(json: Data("{}".utf8), files: [ReportFile(input: "", output: file.path,
            success: true, skipped: false, message: "", width: 16, height: 8)])
        return try await env.sessions.publishExport(photo.id, export: version.id, report: report)
    }
    private func age(_ env: JobEnvironment, _ photo: PhotoSession) throws {
        let path = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/session.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        json["lastUsedAt"] = Date().addingTimeInterval(-172_800).timeIntervalSince1970
        try JSONSerialization.data(withJSONObject: json).write(to: path)
    }

    @Test func twentyFirstPublicationTrimsGloballyWithoutRenumberingOrTouchingPending() async throws {
        let env = try JobEnvironment(), a = try await env.photo("a.png"), b = try await env.photo("b.png")
        let first = try await publish(env, a)
        let pending = try await env.sessions.prepareExport(a.id, options: [:], key: ExportKey(rawValue: "fixture"))
        let orphan = pending.directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([1]).write(to: orphan.appendingPathComponent("unfinished.tif"))
        for _ in 0..<19 { _ = try await publish(env, b) }
        #expect(await env.sessions.exports(for: a.id).count == 1)
        let last = try await publish(env, b)
        #expect(await env.sessions.exports(for: a.id).isEmpty)
        let records = await env.sessions.exports(for: b.id)
        #expect(records.count == 20)
        #expect(await env.sessions.recentExports().map(\.id) == records.map(\.id))
        #expect(Set(records.map(\.sequence)) == Set(1...20))
        #expect(last.sequence == 20)
        #expect(FileManager.default.fileExists(atPath: pending.directory.path))
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        _ = try await publish(env, b)
        #expect(await env.sessions.exports(for: b.id).map(\.sequence).sorted() == Array(2...21))
        try await env.sessions.markSaved(a.id, export: first.id, saved: SavedMark(fileName: "trimmed.tif", folderDisplayName: "out"))
        #expect(!FileManager.default.fileExists(atPath: pending.directory.deletingLastPathComponent().appendingPathComponent(first.id.rawValue).path))
        await env.sessions.discardExport(a.id, export: pending.id)
    }

    @Test func retainedSessionsSurviveTTLAndCanReopenButLaunchRestoreStillExpires() async throws {
        let env = try JobEnvironment(historyLimit: 1), a = try await env.photo("a.png")
        _ = try await publish(env, a)
        await env.sessions.close(a.id); try age(env, a)
        #expect(await env.sessions.cleanupExpired() == 0)
        guard case .none = await env.sessions.restoreLastOutcome() else { Issue.record("Expired launch restore must stay disabled"); return }
        let reopened = try await env.sessions.open(a.sourceURL)
        #expect(reopened.id == a.id)
        #expect(await env.sessions.exports(for: a.id).count == 1)
        await env.sessions.close(a.id); try age(env, a)
        let b = try await env.photo("b.png")
        _ = try await publish(env, b)
        #expect(await env.sessions.cleanupExpired() == 1)
        let root = env.configuration.supportDirectory.appendingPathComponent("sessions/\(a.id)")
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func trimmingDuringAnOpenCopyDoesNotInterruptSaving() async throws {
        let env = try JobEnvironment(historyLimit: 1), photo = try await env.photo()
        let first = try await publish(env, photo)
        let arrived = Mutex(false), gate = BlockingJobGate()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { fd, buffer, count in
                let block = arrived.withLock { value in if value { return false }; value = true; return true }
                if block { gate.waitForRelease() }
                return Darwin.read(fd,buffer,count)
            })
        let folder = env.root.appendingPathComponent("saved")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let save = Task { try await target.save(session: photo.id, export: first.id, oneOff: folder) }
        defer { gate.release() }
        try #require(await eventually(timeout: .seconds(10)) { arrived.withLock { $0 } })
        _ = try await publish(env, photo)
        #expect(await env.sessions.exports(for: photo.id).count == 1)
        #expect(await env.sessions.exports(for: photo.id).first?.id != first.id)
        gate.release()
        let result = try await save.value
        #expect(!gate.didTimeOut)
        #expect(try Data(contentsOf: result.url) == Data([1,2,3]))
        try await env.sessions.markSaved(photo.id, export: first.id, saved: SavedMark(fileName: result.name, folderDisplayName: result.folderDisplayName))
        #expect(await env.sessions.exports(for: photo.id).count == 1)
    }
}

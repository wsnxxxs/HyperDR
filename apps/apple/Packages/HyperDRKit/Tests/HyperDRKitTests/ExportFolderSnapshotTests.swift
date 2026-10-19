import Foundation
import HyperDREngine
import Synchronization
import Testing
@testable import HyperDRKit

private final class FolderSnapshotAccess: SecurityScopedAccess {
    private let count = Mutex(0)
    var active: Int { count.withLock { $0 } }
    func startAccessing(_ url: URL) -> Bool { count.withLock { $0 += 1 }; return true }
    func stopAccessing(_ url: URL) { count.withLock { $0 -= 1 } }
}

struct ExportFolderSnapshotTests {
    @Test func revealUsesCapturedAuthorityAfterRenameAndPreferenceChange() async throws {
        let env = try JobEnvironment(), access = FolderSnapshotAccess()
        let opened = Mutex<[URL]>([])
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access,
            openFolder: { url in
                #expect(access.active > 0)
                opened.withLock { $0.append(url) }
                return true
            })
        let alpha = env.root.appendingPathComponent("alpha"), beta = env.root.appendingPathComponent("beta")
        for url in [alpha, beta] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        _ = try await target.setFolder(alpha)
        let captured = try await target.captureFolder()
        _ = try await target.setFolder(beta)
        let moved = env.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: alpha, to: moved)
        try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: beta)
        try await target.reveal(folder: captured)
        #expect(opened.withLock { $0.map { $0.resolvingSymlinksInPath().path } } == [moved.resolvingSymlinksInPath().path])
        let denied = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access, openFolder: { _ in false })
        do { try await denied.reveal(folder: captured); Issue.record("Expected opener failure") }
        catch { #expect((error as? HyperDREngine.HyperDRError)?.code == "export_folder_unwritable") }
    }

    @Test func capturedDirectoryMovedIntoWorkspaceIsStillExcludedByIdentity() async throws {
        let env = try JobEnvironment(), access = FolderSnapshotAccess()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access)
        let alpha = env.root.appendingPathComponent("alpha")
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        _ = try await target.setFolder(alpha)
        let captured = try await target.captureFolder()
        let photo = try await env.photo(), runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let moved = env.configuration.supportDirectory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: alpha, to: moved)
        do {
            _ = try await target.save(session: photo.id, export: ticket.export, folder: captured)
            Issue.record("A snapshot must not authorize writing into the workspace after a move")
        } catch { #expect((error as? HyperDRError)?.code == "export_folder_inside_workspace") }
        #expect(access.active == 1, "A rejected save releases its renewed scope")
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    @Test func capturedAuthoritySurvivesPreferenceChangesAndDirectoryRename() async throws {
        let env = try JobEnvironment(), access = FolderSnapshotAccess()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access)
        let alpha = env.root.appendingPathComponent("alpha"), beta = env.root.appendingPathComponent("beta")
        for path in [alpha, beta] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let photo = try await env.photo(), runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        _ = try await target.setFolder(alpha)
        #expect(access.active == 0)
        weak var released: ExportFolderSnapshot?
        do {
            let captured = try await target.captureFolder()
            released = captured
            #expect(access.active == 1)
            _ = try await target.setFolder(beta)
            #expect(access.active == 1, "The old grant remains held while preferences change")
            let moved = env.root.appendingPathComponent("alpha-moved")
            try FileManager.default.moveItem(at: alpha, to: moved)
            try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: beta)
            let saved = try await target.save(session: photo.id, export: ticket.export, folder: captured)
            #expect(saved.url.deletingLastPathComponent().resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
            let source = try await env.sessions.resultURL(photo.id, export: ticket.export)
            #expect(try Data(contentsOf: saved.url) == Data(contentsOf: source))
            #expect(try FileManager.default.contentsOfDirectory(atPath: beta.path).isEmpty)
        }
        #expect(released == nil)
        try #require(await eventually(timeout: .seconds(10)) { access.active == 0 })
        let next = try await target.captureFolder()
        let saved = try await target.save(session: photo.id, export: ticket.export, folder: next)
        #expect(saved.url.deletingLastPathComponent().resolvingSymlinksInPath().path == beta.resolvingSymlinksInPath().path)
    }
}

private func eventually(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

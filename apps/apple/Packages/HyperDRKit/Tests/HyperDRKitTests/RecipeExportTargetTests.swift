import Darwin
import Foundation
import HyperDREngine
import Synchronization
import Testing
@testable import HyperDRKit

private final class TargetScopeAccess: SecurityScopedAccess {
    private let count = Mutex(0)
    var active: Int { count.withLock { $0 } }
    func startAccessing(_ url: URL) -> Bool { count.withLock { $0 += 1 }; return true }
    func stopAccessing(_ url: URL) { count.withLock { $0 -= 1 } }
}

/// Landing-file tests: export one tiny Fake-rendered JPEG, then exercise only
/// target publication, permissions and history. No pixel/codec assertions here.
@Suite(.timeLimit(.minutes(1))) struct RecipeExportTargetTests {
    private func folder(_ env: RecipeExportEnvironment, _ name: String) throws -> URL {
        let url = env.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exported(_ env: RecipeExportEnvironment) async throws -> RecipeExportResult {
        try await env.service().export(session: env.session.id, snapshot: env.snapshot(), request: env.request(.sdrJPEG))
    }

    @Test func concurrentVersionsAndFolderCopiesUseDistinctNumbers() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let snapshot = try env.snapshot(), request = env.request(.sdrJPEG)
        let firstService = env.service(), secondService = env.service()
        async let a = firstService.export(session: env.session.id, snapshot: snapshot, request: request)
        async let b = secondService.export(session: env.session.id, snapshot: snapshot, request: request)
        let versions = try await [a, b]
        #expect(Set(versions.map { $0.record.sequence }) == Set([1, 2]))
        #expect(Set(versions.map { $0.record.id }).count == 2)
        #expect(Set(await env.sessions.exports(for: env.session.id).map(\.id)) == Set(versions.map { $0.record.id }))
        let directory = try folder(env, "numbered")
        let name = versions[0].file.lastPathComponent
        #expect(versions[1].file.lastPathComponent == name)
        let old = Data([9, 8, 7]), existing = directory.appendingPathComponent(name)
        try old.write(to: existing)
        async let copyA = env.target.save(session: env.session.id, export: versions[0].record.id, oneOff: directory)
        async let copyB = env.target.save(session: env.session.id, export: versions[1].record.id, oneOff: directory)
        let copies = try await [copyA, copyB]
        let stem = existing.deletingPathExtension().lastPathComponent, ext = existing.pathExtension
        #expect(Set(copies.map(\.name)) == Set(["\(stem) (2).\(ext)", "\(stem) (3).\(ext)"]))
        #expect(try Data(contentsOf: existing) == old)
        for (copy, version) in zip(copies, versions) {
            #expect(try Data(contentsOf: copy.url) == Data(contentsOf: version.file))
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set([name] + copies.map(\.name)))
    }

    @Test func selectedFilenameReplacesAtomicallyAndValidationDoesNotWrite() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let result = try await exported(env), directory = try folder(env, "selected")
        let destination = directory.appendingPathComponent("chosen.jpg"), old = Data([9, 8, 7])
        try old.write(to: destination)
        let reader = try FileHandle(forReadingFrom: destination)
        defer { try? reader.close() }
        try await env.target.validateDestination(destination, expectedExtension: "jpg")
        #expect(try Data(contentsOf: destination) == old)
        let fresh = directory.appendingPathComponent("new.jpg")
        try await env.target.validateDestination(fresh, expectedExtension: "jpg")
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        do {
            try await env.target.validateDestination(directory.appendingPathComponent("wrong.tif"), expectedExtension: "jpg")
            Issue.record("Expected invalid extension")
        } catch let error as HyperDRError { #expect(error.code == "invalid_options") }
        let saved = try await env.target.save(session: env.session.id, export: result.record.id, to: destination)
        #expect(saved.name == "chosen.jpg")
        #expect(try Data(contentsOf: saved.url) == Data(contentsOf: result.file))
        #expect(try reader.readToEnd() == old, "Replacement must preserve an already-open old inode")
        #expect(await env.target.folder.ready == false, "Selected files must not change fixed-folder preferences")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["chosen.jpg"])
    }

    @Test func interruptedCopiesCleanStagingAndFallbackNeverTruncatesOldFiles() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let result = try await exported(env), directory = try folder(env, "failures")
        let replacementRoot = try folder(env, "replacement-staging")
        let old = Data([9, 8, 7]), destination = directory.appendingPathComponent("keep.jpg")
        try old.write(to: destination)
        // Exercise normal directory staging, selected-file replacement staging,
        // and the no-replacement-directory fallback (new files only).
        for mode in 0..<3 { for cancel in [false, true] {
            let readOnce = Mutex(false)
            var hooks = ExportTarget.CopyHooks()
            hooks.replacementDirectory = { _ in
                if mode == 2 { throw CocoaError(.fileWriteNoPermission) }
                let staging = replacementRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                return staging
            }
            hooks.read = { fd, bytes, count in
                if readOnce.withLock({ first in defer { first = true }; return first }) {
                    errno = EIO; return -1
                }
                let copied = Darwin.read(fd, bytes, count)
                if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                return copied
            }
            let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
                access: SystemSecurityScopedAccess(), hooks: hooks)
            do {
                if mode == 0 {
                    _ = try await target.save(session: env.session.id, export: result.record.id, oneOff: directory)
                } else {
                    _ = try await target.save(session: env.session.id, export: result.record.id,
                        to: mode == 1 ? destination : directory.appendingPathComponent("partial.jpg"))
                }
                Issue.record("Expected interrupted copy for mode \(mode), cancel=\(cancel)")
            } catch is CancellationError { #expect(cancel) }
            catch let error as HyperDRError { #expect(!cancel && error.code == "export_folder_unwritable") }
            #expect(readOnce.withLock { $0 }, "Interrupt after copying actual bytes")
            #expect(try Data(contentsOf: destination) == old)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["keep.jpg"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: replacementRoot.path).isEmpty)
        } }
        var hooks = ExportTarget.CopyHooks()
        hooks.replacementDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }
        let fallback = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do {
            _ = try await fallback.save(session: env.session.id, export: result.record.id, to: destination)
            Issue.record("Replacement without an atomic staging directory must be rejected")
        } catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(try Data(contentsOf: destination) == old)
        let fresh = directory.appendingPathComponent("new.jpg")
        let saved = try await fallback.save(session: env.session.id, export: result.record.id, to: fresh)
        #expect(try Data(contentsOf: saved.url) == Data(contentsOf: result.file))
        #expect(await env.sessions.exports(for: env.session.id).map(\.id) == [result.record.id])
    }

    @Test func capturedBookmarkSurvivesPreferenceChangesAndStillExcludesWorkspace() async throws {
        let env = try await RecipeExportEnvironment(); defer { env.remove() }
        let result = try await exported(env), access = TargetScopeAccess()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access)
        let alpha = try folder(env, "alpha"), beta = try folder(env, "beta"), once = try folder(env, "once")
        _ = try await target.setFolder(alpha)
        weak var released: ExportFolderSnapshot?
        do {
            let captured = try await target.captureFolder()
            released = captured
            #expect(access.active == 1)
            _ = try await target.setFolder(beta)
            let moved = env.root.appendingPathComponent("alpha-moved", isDirectory: true)
            try FileManager.default.moveItem(at: alpha, to: moved)
            try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: env.configuration.supportDirectory)
            let saved = try await target.save(session: env.session.id, export: result.record.id, folder: captured)
            #expect(saved.url.deletingLastPathComponent().resolvingSymlinksInPath().path == moved.resolvingSymlinksInPath().path)
            #expect(try Data(contentsOf: saved.url) == Data(contentsOf: result.file))
            #expect(try FileManager.default.contentsOfDirectory(atPath: beta.path).isEmpty)
            #expect(access.active == 1)
            let inside = env.configuration.supportDirectory.appendingPathComponent("moved-inside", isDirectory: true)
            try FileManager.default.moveItem(at: moved, to: inside)
            do {
                _ = try await target.save(session: env.session.id, export: result.record.id, folder: captured)
                Issue.record("A captured folder moved into workspace must be rejected")
            } catch let error as HyperDRError { #expect(error.code == "export_folder_inside_workspace") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: inside.path) == [saved.name])
            #expect(access.active == 1, "Rejected save must release its renewed scope")
        }
        #expect(released == nil && access.active == 0)
        _ = try await target.save(session: env.session.id, export: result.record.id, oneOff: once)
        let restored = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access)
        #expect(await restored.folder.ready)
        #expect(await restored.folder.label.hasSuffix("/beta"))
        let saved = try await restored.save(session: env.session.id, export: result.record.id)
        #expect(saved.url.deletingLastPathComponent().resolvingSymlinksInPath().path == beta.resolvingSymlinksInPath().path)
        #expect(try Data(contentsOf: saved.url) == Data(contentsOf: result.file))
        #expect(access.active == 0)
    }
}

import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private let reviewPNG: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    + [UInt8](repeating: 0x20, count: 64)

private final class CountingAccess: SecurityScopedAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var urls: [URL] = []

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock {
            starts += 1
            urls.append(url)
        }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }

    func reset() {
        lock.withLock {
            starts = 0
            stops = 0
            urls = []
        }
    }

    var counts: (starts: Int, stops: Int) {
        lock.withLock { (starts, stops) }
    }

    var startedURLs: [URL] {
        lock.withLock { urls }
    }
}

private final class ReviewEnvironment {
    let root: URL
    let support: URL
    let cache: URL
    let sources: URL
    let formats: InputFormats
    let access = CountingAccess()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-k1-review-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        for directory in [support, cache, sources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        formats = try InputFormats(schema: Engine.schema())
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func store(ttl: Duration = .seconds(3600)) -> SessionStore {
        SessionStore(configuration: KitConfiguration(supportDirectory: support,
            cacheDirectory: cache, sessionTTL: ttl), formats: formats,
            decodeCacheMaxAge: 3600, decodeCacheMaxBytes: 1 << 20, access: access)
    }

    func source(_ name: String, bytes: [UInt8] = reviewPNG) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func largeSource(_ name: String, megabytes: Int = 96) throws -> URL {
        let url = sources.appendingPathComponent(name)
        var bytes = reviewPNG
        let total = megabytes << 20
        bytes.append(contentsOf: [UInt8](repeating: 0x20, count: total - bytes.count))
        try Data(bytes).write(to: url)
        return url
    }

    func sessionDirectory(_ id: SessionID) -> URL {
        support.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    func exportsDirectory(_ id: SessionID) -> URL {
        sessionDirectory(id).appendingPathComponent("exports", isDirectory: true)
    }

    func appendByte(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x07]))
    }

    func makeExpired(_ id: SessionID) throws {
        let file = sessionDirectory(id).appendingPathComponent("session.json")
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["lastUsedAt"] = 0
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
    }
}

private func waitUntil(timeout: Duration = .seconds(2),
                       _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func runTool(_ path: String, _ arguments: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch { return false }
}

private func requireHyperDRError(_ body: () async throws -> Void) async -> String? {
    do {
        try await body()
        return nil
    } catch let error as HyperDRError {
        return error.code
    } catch {
        return "unexpected:\(error)"
    }
}

@Suite(.serialized) struct K1ReviewRegressionTests {
    // MARK: P1-1 path escapes

    @Test func discardDoesNotTraverseSymlinkedExports() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let outside = environment.root.appendingPathComponent("outside", isDirectory: true)
        let export = ExportID(rawValue: String(repeating: "a", count: 32))
        let victim = outside.appendingPathComponent(export.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data([1]).write(to: victim.appendingPathComponent("KEEP"))

        let exports = environment.exportsDirectory(session.id)
        try FileManager.default.removeItem(at: exports)
        try FileManager.default.createSymbolicLink(at: exports, withDestinationURL: outside)

        await store.discardExport(session.id, export: export)

        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("KEEP").path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        await store.close(session.id)
    }

    @Test func discardDoesNotTraverseASymlinkedExportDirectory() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let outside = environment.root.appendingPathComponent("outside", isDirectory: true)
        let export = ExportID(rawValue: String(repeating: "b", count: 32))
        let victim = outside.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data([2]).write(to: victim.appendingPathComponent("KEEP"))
        try FileManager.default.createSymbolicLink(
            at: environment.exportsDirectory(session.id).appendingPathComponent(export.rawValue),
            withDestinationURL: victim)

        await store.discardExport(session.id, export: export)

        #expect(FileManager.default.fileExists(atPath: victim.appendingPathComponent("KEEP").path))
        await store.close(session.id)
    }

    @Test func resultURLRejectsASymlinkedResultFile() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.source("photo.png")
        let session = try await store.open(source)
        let (export, folder) = try await store.prepareExport(session.id, options: [:])
        let output = folder.appendingPathComponent("result.jpg")
        try Data([1, 2, 3]).write(to: output)
        let report = ConvertReport(json: Data("{}".utf8), files: [ReportFile(
            input: source.path, output: output.path, success: true, skipped: false,
            message: "", width: 1, height: 1)])
        let record = try await store.publishExport(session.id, export: export, report: report)
        #expect(try await store.resultURL(session.id, export: record.id) == output)

        let outside = environment.root.appendingPathComponent("outside.jpg")
        try Data([9, 9, 9]).write(to: outside)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: outside)

        #expect(await requireHyperDRError {
            _ = try await store.resultURL(session.id, export: record.id)
        } == "source_missing")
        #expect(await store.exports(for: session.id).isEmpty)
        await store.close(session.id)
    }

    @Test func cleanupRemovesASessionWithASymlinkedExportsWithoutTouchingOutside() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        await store.close(session.id)
        try environment.makeExpired(session.id)

        let outside = environment.root.appendingPathComponent("outside-cleanup", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([3]).write(to: outside.appendingPathComponent("KEEP"))
        let exports = environment.exportsDirectory(session.id)
        try FileManager.default.removeItem(at: exports)
        try FileManager.default.createSymbolicLink(at: exports, withDestinationURL: outside)

        let removed = await environment.store().cleanupExpired(now: Date().addingTimeInterval(100_000))

        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(session.id).path))
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("KEEP").path))
    }

    // MARK: P1-2 security scope ordering

    @Test func openLeasesTheOriginalURLBeforeInspectingTheFile() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let missing = environment.sources.appendingPathComponent("missing.png")

        #expect(await requireHyperDRError { _ = try await store.open(missing) } == "source_unreadable")
        #expect(environment.access.counts == (1, 1))
        #expect(environment.access.startedURLs == [missing])
    }

    @Test func openLeasesASymlinkAliasRatherThanItsCanonicalTarget() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let target = try environment.source("target.png")
        let alias = environment.sources.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let session = try await store.open(alias)
        #expect(environment.access.startedURLs == [alias])
        #expect(session.sourceURL.path == target.resolvingSymlinksInPath().path)
        await store.close(session.id)
        #expect(environment.access.counts == (1, 1))
    }

    @Test func bookmarkActivationLeasesAndReleasesTheResolvedURL() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        await store.close(session.id)
        #expect(environment.access.counts == (1, 1))

        environment.access.reset()
        let secondStore = environment.store()
        let reopened = try await secondStore.session(session.id)
        #expect(reopened.id == session.id)
        #expect(environment.access.counts == (1, 0))
        await secondStore.close(session.id)
        #expect(environment.access.counts == (1, 1))
    }

    // MARK: P1-3 actor reentrancy

    @Test func concurrentSessionLookupsShareOneActivationLease() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("large.png")
        let session = try await store.open(source)
        await store.close(session.id)
        #expect(environment.access.counts == (1, 1))

        environment.access.reset()
        try environment.appendByte(to: source)
        async let first = store.session(session.id)
        async let second = store.session(session.id)
        _ = try await (first, second)
        #expect(environment.access.counts == (1, 0))

        await store.close(session.id)
        #expect(environment.access.counts == (1, 1))
    }

    @Test func closeDuringActivationDoesNotBlockCleanupOrWriteASession() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("large.png")
        let session = try await store.open(source)
        await store.close(session.id)
        environment.access.reset()
        try environment.appendByte(to: source)

        let activation = Task { try await store.session(session.id) }
        try await Task.sleep(for: .milliseconds(3))
        await store.close(session.id)
        let removed = await store.cleanupExpired(now: Date().addingTimeInterval(100_000))

        var activationError: Error?
        do { _ = try await activation.value }
        catch { activationError = error }
        if let error = activationError as? HyperDRError {
            #expect(error.code == "cancelled")
        } else {
            #expect(activationError == nil)
        }
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(session.id).path))
        #expect(environment.access.counts == (1, 1))
    }

    @Test func closeDuringRefreshDoesNotResurrectTheSession() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("large.png")
        let session = try await store.open(source)
        environment.access.reset()
        try environment.appendByte(to: source)

        let refresh = Task { try await store.session(session.id) }
        try await Task.sleep(for: .milliseconds(3))
        await store.close(session.id)
        var refreshError: Error?
        do { _ = try await refresh.value }
        catch { refreshError = error }
        if let error = refreshError as? HyperDRError {
            #expect(error.code == "cancelled")
        } else {
            #expect(refreshError == nil)
        }

        let removed = await store.cleanupExpired(now: Date().addingTimeInterval(100_000))
        #expect(removed == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(session.id).path))
        // Refreshing an already-open session reuses its lease, so only close()
        // contributes a stop after the counter reset.
        #expect(environment.access.counts == (0, 1))
    }

    // MARK: P2-4 pending recovery

    @Test func orphanPendingIsClearedWithoutDeletingTheSession() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let (_, folder) = try await store.prepareExport(session.id, options: [:])
        await store.close(session.id)

        let fresh = environment.store()
        let removed = await fresh.cleanupExpired(now: Date())

        #expect(removed == 0)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: environment.sessionDirectory(session.id).path))
    }

    @Test func interruptedPublishPromotesTheFinalManifest() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let (export, folder) = try await store.prepareExport(session.id, options: [:])
        let output = folder.appendingPathComponent("final.jpg")
        try Data([4, 5, 6]).write(to: output)
        let record = ExportRecord(id: export, name: "final.jpg", byteCount: 3,
            createdAt: Date(), sourceDigest: session.sha256, options: [:],
            reportJSON: Data("{}".utf8))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: folder.appendingPathComponent("pending.json"))
        await store.close(session.id)

        let fresh = environment.store()
        _ = await fresh.cleanupExpired(now: Date())

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.json").path))
        let records = await fresh.exports(for: session.id)
        #expect(records.count == 1)
        #expect(records.first?.id == export)
        #expect(try await fresh.resultURL(session.id, export: export) == output)
        await fresh.close(session.id)
    }

    @Test func publishedResultWinsOverALeftoverPendingManifest() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let (export, folder) = try await store.prepareExport(session.id, options: [:])
        let output = folder.appendingPathComponent("final.jpg")
        try Data([7]).write(to: output)
        let record = ExportRecord(id: export, name: "final.jpg", byteCount: 1,
            createdAt: Date(), sourceDigest: session.sha256, options: [:],
            reportJSON: Data("{}".utf8))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(record).write(to: folder.appendingPathComponent("result.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("pending.json"))
        await store.close(session.id)

        let fresh = environment.store()
        _ = await fresh.cleanupExpired(now: Date())

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("pending.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("result.json").path))
        #expect(await fresh.exports(for: session.id).count == 1)
    }

    // MARK: P2-6 public error mapping

    @Test func cancelledHashMapsToHyperDRErrorCancelled() async throws {
        let environment = try ReviewEnvironment()
        let source = try environment.largeSource("large-cancel.png", megabytes: 512)
        let store = environment.store()
        let task = Task { try await store.open(source) }
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()

        var outcome = "none"
        do {
            let session = try await task.value
            outcome = "success:\(session.byteCount)"
        } catch let error as HyperDRError {
            outcome = "error:\(error.code)"
        } catch {
            outcome = "error:\(error)"
        }
        #expect(outcome == "error:cancelled", Comment(rawValue: outcome))
        #expect(environment.access.counts.starts == environment.access.counts.stops)
    }

    @Test func fileHandleFailuresMapToSourceUnreadable() async throws {
        let environment = try ReviewEnvironment()
        let missing = environment.sources.appendingPathComponent("missing-large.png")
        #expect(await requireHyperDRError {
            _ = try await environment.store().sha256(missing)
        } == "source_unreadable")
    }

    // MARK: P2-5 cleanup scheduling

    @Test func compositionRootRunsStartupCleanupAndStopsItsLoop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-k1-schedule-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let configuration = KitConfiguration(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true))
        let kit = try await HyperDRKit(configuration: configuration, cleanupInterval: .milliseconds(40))

        func makeSession(_ name: String, id: inout SessionID) async throws {
            let source = sources.appendingPathComponent(name)
            try Data(reviewPNG).write(to: source)
            let session = try await kit.sessions.open(source)
            id = session.id
            await kit.sessions.close(session.id)
            let file = configuration.supportDirectory
                .appendingPathComponent("sessions/\(session.id.rawValue)/session.json")
            var object = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            object["lastUsedAt"] = 0
            try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        }

        var startupSession = SessionID(rawValue: String(repeating: "0", count: 32))
        try await makeSession("startup.png", id: &startupSession)
        await kit.start()
        #expect(!FileManager.default.fileExists(atPath: configuration.supportDirectory
            .appendingPathComponent("sessions/\(startupSession.rawValue)").path))

        // Starting again is idempotent and does not create a second loop.
        await kit.start()
        kit.stop()

        var stoppedSession = SessionID(rawValue: String(repeating: "0", count: 32))
        try await makeSession("stopped.png", id: &stoppedSession)
        try await Task.sleep(for: .milliseconds(250))
        #expect(FileManager.default.fileExists(atPath: configuration.supportDirectory
            .appendingPathComponent("sessions/\(stoppedSession.rawValue)").path))

        _ = await kit.sessions.cleanupExpired(now: Date().addingTimeInterval(100_000))
    }

    @Test func cancellingTheOpenCreatorKeepsTheSurvivingWaitersLease() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("large-creator.png", megabytes: 512)
        let access = environment.access

        let creator = Task { try await store.open(source) }
        #expect(await waitUntil { access.counts.starts == 1 })
        let waiter = Task { try await store.open(source) }
        #expect(await waitUntil { access.counts.starts == 2 })
        creator.cancel()

        var creatorFailure: HyperDRError?
        do { _ = try await creator.value }
        catch let error as HyperDRError { creatorFailure = error }
        #expect(creatorFailure?.code == "cancelled")

        let session = try await waiter.value
        #expect(environment.access.counts == (2, 1))
        await store.close(session.id)
        #expect(environment.access.counts == (2, 2))
    }

    @Test func cancellingAJoinerDoesNotStopTheCreatorsLease() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("large-joiner.png", megabytes: 512)
        let access = environment.access

        let creator = Task { try await store.open(source) }
        #expect(await waitUntil { access.counts.starts == 1 })
        let waiter = Task { try await store.open(source) }
        #expect(await waitUntil { access.counts.starts == 2 })
        waiter.cancel()

        var waiterFailure: HyperDRError?
        do { _ = try await waiter.value }
        catch let error as HyperDRError { waiterFailure = error }
        #expect(waiterFailure?.code == "cancelled")

        let session = try await creator.value
        #expect(environment.access.counts == (2, 1))
        await store.close(session.id)
        #expect(environment.access.counts == (2, 2))
    }

    @Test func deletionRefusesToCrossAMountedFilesystem() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let session = try await store.open(try environment.source("photo.png"))
        let (export, folder) = try await store.prepareExport(session.id, options: [:])
        await store.close(session.id)

        let image = environment.root.appendingPathComponent("mount-test.dmg")
        guard runTool("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "APFS",
            "-volname", "HyperDRMountTest", "-quiet", image.path]) else {
            print("mount boundary test skipped: hdiutil create unavailable")
            return
        }
        let mountPoint = folder.appendingPathComponent("mounted-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        var mounted = false
        defer {
            if mounted {
                _ = runTool("/usr/bin/hdiutil", ["detach", "-force", mountPoint.path, "-quiet"])
            }
        }
        guard runTool("/usr/bin/hdiutil", ["attach", "-nobrowse", "-noautoopen",
            "-mountpoint", mountPoint.path, "-quiet", image.path]) else {
            print("mount boundary test skipped: hdiutil attach unavailable")
            return
        }
        mounted = true
        let marker = mountPoint.appendingPathComponent("KEEP")
        try Data([1]).write(to: marker)

        await store.discardExport(session.id, export: export)
        #expect(FileManager.default.fileExists(atPath: marker.path))

        try environment.makeExpired(session.id)
        let removed = await environment.store().cleanupExpired(
            now: Date().addingTimeInterval(100_000))
        #expect(removed == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}


extension K1ReviewRegressionTests {
    @Test(.timeLimit(.minutes(1))) func cancelledActivationCreatorKeepsASurvivingWaitersLease() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let source = try environment.largeSource("activation-shared.png", megabytes: 512)
        let photo = try await store.open(source)
        await store.close(photo.id)
        try environment.appendByte(to: source)
        let access = environment.access
        let creator = Task { await store.restoreLastOutcome() }
        try #require(await waitUntil { access.counts.starts == 2 })
        let survivor = Task { try await store.session(photo.id) }
        // The changed 512 MB source holds activation in its asynchronous hash;
        // give the second waiter an actor turn before cancelling the creator.
        try await Task.sleep(for: .milliseconds(20))
        creator.cancel()
        guard case .unavailable(let failure) = await creator.value else {
            Issue.record("Expected cancelled creator"); return
        }
        #expect(failure.code == "cancelled")
        let claimed = try await survivor.value
        #expect(claimed.id == photo.id)
        #expect(environment.access.counts == (2, 1))
        await store.close(photo.id)
        #expect(environment.access.counts == (2, 2))
    }

    @Test(.timeLimit(.minutes(1))) func cancelledRefreshDoesNotReleaseAnAlreadyOpenLease() async throws {
        let environment = try ReviewEnvironment()
        let store = environment.store()
        let photo = try await store.open(environment.source("already-open.png"))
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.restoreLastOutcome()
        }
        guard case .unavailable(let failure) = await caller.value else {
            Issue.record("Expected cancellation"); return
        }
        #expect(failure.code == "cancelled")
        #expect(environment.access.counts == (1, 0))
        #expect(try await store.session(photo.id).id == photo.id)
        await store.close(photo.id)
        #expect(environment.access.counts == (1, 1))
    }
}

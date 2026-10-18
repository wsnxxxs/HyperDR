import CryptoKit
import Darwin
import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private let pngBytes: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    + [UInt8](repeating: 0x20, count: 64)
private let heicBytes: [UInt8] = [0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
                                  0x68, 0x65, 0x69, 0x63] + [UInt8](repeating: 0x20, count: 64)

private final class TestEnvironment {
    let root: URL
    let support: URL
    let cache: URL
    let sources: URL
    let formats: InputFormats

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-session-\(UUID().uuidString)", isDirectory: true)
        support = root.appendingPathComponent("support", isDirectory: true)
        cache = root.appendingPathComponent("cache", isDirectory: true)
        sources = root.appendingPathComponent("sources", isDirectory: true)
        for directory in [support, cache, sources] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        formats = try InputFormats(schema: Engine.schema())
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func source(_ name: String, _ bytes: [UInt8] = pngBytes) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func store(ttl: Duration = .seconds(3600), maxAge: TimeInterval = 7 * 24 * 60 * 60,
               maxBytes: Int64 = 4 << 30) -> SessionStore {
        SessionStore(configuration: KitConfiguration(supportDirectory: support,
            cacheDirectory: cache, sessionTTL: ttl), formats: formats,
            decodeCacheMaxAge: maxAge, decodeCacheMaxBytes: maxBytes)
    }

    func sessionDirectory(_ id: SessionID) -> URL {
        support.appendingPathComponent("sessions").appendingPathComponent(id.rawValue)
    }
}

/// Rewrites `url` in place with as many bytes as it had, then puts the
/// access and modification times back to the nanosecond: only the ctime moves.
private func rewriteKeepingTimes(_ url: URL, _ bytes: [UInt8]) throws {
    let fd = open(url.path, O_RDWR | O_CLOEXEC)
    try #require(fd >= 0)
    defer { close(fd) }
    var before = stat()
    try #require(fstat(fd, &before) == 0)
    try #require(Int(before.st_size) == bytes.count)
    try #require(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == bytes.count)
    var times = [before.st_atimespec, before.st_mtimespec]
    try #require(futimens(fd, &times) == 0)
    var after = stat()
    try #require(fstat(fd, &after) == 0)
    try #require(after.st_size == before.st_size
        && after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
        && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Suite struct SessionStoreTests {
    @Test func restoreOutcomeDistinguishesHistoryFromUnavailableSource() async throws {
        let environment = try TestEnvironment()
        let store = environment.store()
        guard case .none = await store.restoreLastOutcome() else {
            Issue.record("Expected empty history"); return
        }
        let source = try environment.source("restore.png")
        let photo = try await store.open(source)
        await store.close(photo.id)
        let restoredStore = environment.store()
        guard case .restored(let restored) = await restoredStore.restoreLastOutcome() else {
            Issue.record("Expected restored photo"); return
        }
        #expect(restored.id == photo.id)
        await restoredStore.close(photo.id)
        try FileManager.default.removeItem(at: source)
        guard case .unavailable(let failure) = await store.restoreLastOutcome() else {
            Issue.record("Expected unavailable source"); return
        }
        #expect(failure.code == "source_missing")
        guard case .none = await store.restoreLastOutcome() else {
            Issue.record("Expected cleared history"); return
        }
        #expect(await store.restoreLast() == nil)
    }

    @Test func cancelledRestorePreservesHistory() async throws {
        let environment = try TestEnvironment()
        let store = environment.store()
        let photo = try await store.open(try environment.source("cancelled.png"))
        await store.close(photo.id)
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.restoreLastOutcome()
        }.value
        guard case .unavailable(let failure) = outcome else {
            Issue.record("Expected cancelled restore"); return
        }
        #expect(failure.code == "cancelled")
        guard case .restored(let restored) = await store.restoreLastOutcome() else {
            Issue.record("Cancellation must preserve history"); return
        }
        #expect(restored.id == photo.id)
        await store.close(photo.id)
    }

    @Test func expiredRestoreHistoryIsNormal() async throws {
        let environment = try TestEnvironment()
        let store = environment.store()
        let photo = try await store.open(try environment.source("expired.png"))
        await store.close(photo.id)
        let expired = environment.store(ttl: .seconds(-1))
        guard case .none = await expired.restoreLastOutcome() else {
            Issue.record("Expected expired history to be absent"); return
        }
    }

    @Test func openStoresMetadataReusesDigestAndRestoresBookmark() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let first = try await store.open(source)
        #expect(first.displayName == "photo.png")
        #expect(first.byteCount == Int64(pngBytes.count))
        #expect(first.sha256 == sha256(pngBytes))
        #expect(first.format == .png)
        #expect(first.sourceURL.path == source.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath:
            environment.sessionDirectory(first.id).appendingPathComponent("session.json").path))

        let second = try await store.open(source)
        #expect(second.id == first.id)
        await store.close(first.id)

        let otherStore = environment.store()
        let reopened = try await otherStore.session(first.id)
        #expect(reopened.sha256 == first.sha256)
        #expect(reopened.sourceURL.path == first.sourceURL.path)
        await otherStore.close(first.id)

        let restored = await environment.store().restoreLast()
        #expect(restored?.id == first.id)
    }

    @Test func changedSourceGetsANewSessionAndDigest() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let first = try await store.open(source)
        let changed = pngBytes + [0x01]
        try Data(changed).write(to: source)
        let second = try await store.open(source)
        #expect(second.id != first.id)
        #expect(second.sha256 == sha256(changed))
        #expect(second.sha256 != first.sha256)
        await store.close(first.id)
        await store.close(second.id)

        let reopened = try await environment.store().session(first.id)
        #expect(reopened.sha256 == second.sha256)
    }

    @Test func anOpenSessionRefreshesItsDigestWhenTheSourceChanges() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let first = try await store.open(source)
        let changed = pngBytes + [0x02]
        try Data(changed).write(to: source)
        let refreshed = try await store.session(first.id)
        #expect(refreshed.id == first.id)
        #expect(refreshed.sha256 == sha256(changed))
        #expect(refreshed.sha256 != first.sha256)
        await store.close(first.id)
    }

    /// Stricter than the Python reference, which keys on size + mtime_ns only:
    /// a same-size rewrite with the mtime restored changes the digest, both for
    /// an open session and for a session activated by a new store.
    @Test func sameSizeRewriteWithRestoredMtimeChangesTheDigest() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let first = try await store.open(source)
        var changed = pngBytes
        changed[changed.count - 1] = 0x21
        try rewriteKeepingTimes(source, changed)
        let refreshed = try await store.session(first.id)
        #expect(refreshed.id == first.id)
        #expect(refreshed.sha256 == sha256(changed))
        await store.close(first.id)

        var again = pngBytes
        again[again.count - 1] = 0x22
        try rewriteKeepingTimes(source, again)
        let otherStore = environment.store()
        let activated = try await otherStore.session(first.id)
        #expect(activated.sha256 == sha256(again))
        await otherStore.close(first.id)
    }

    /// The digest is reused while the source facts are unchanged, and computed
    /// again only after they change (`test_external_digest_rehashes_only_after_size_or_mtime_changes`).
    /// A chmod moves the ctime, so it costs one more hash; that is accepted.
    @Test func unchangedSourceIsNotHashedAgain() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let photo = try await store.open(source)
        #expect(await store.digestComputations == 1)
        _ = try await store.session(photo.id)
        _ = try await store.open(source)
        _ = try await store.session(photo.id)
        #expect(await store.digestComputations == 1, "unchanged source was hashed again")

        let changed = pngBytes + [0x03]
        try Data(changed).write(to: source)
        #expect(try await store.session(photo.id).sha256 == sha256(changed))
        #expect(await store.digestComputations == 2)
        _ = try await store.session(photo.id)
        #expect(await store.digestComputations == 2)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        #expect(try await store.session(photo.id).sha256 == sha256(changed))
        #expect(await store.digestComputations == 3)
        await store.close(photo.id)
    }

    @Test func missingSourceAndCorruptBookmarkReportSourceMissing() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let first = try await store.open(source)
        await store.close(first.id)
        try FileManager.default.removeItem(at: source)

        do { _ = try await environment.store().session(first.id); Issue.record("Expected source_missing") }
        catch let error as HyperDRError { #expect(error.code == "source_missing") }
        #expect(await environment.store().restoreLast() == nil)
        #expect(!FileManager.default.fileExists(atPath:
            environment.support.appendingPathComponent("last-session.json").path))

        let secondSource = try environment.source("second.png")
        let second = try await environment.store().open(secondSource)
        await environment.store().close(second.id)
        let file = environment.sessionDirectory(second.id).appendingPathComponent("session.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["sourceBookmark"] = Data([0, 1, 2, 3]).base64EncodedString()
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        do { _ = try await environment.store().session(second.id); Issue.record("Expected source_missing") }
        catch let error as HyperDRError { #expect(error.code == "source_missing") }
    }

    @Test func rejectsEmptyUnsupportedAndMismatchedSources() async throws {
        let environment = try TestEnvironment()
        let store = environment.store()
        let empty = try environment.source("empty.png", [])
        do { _ = try await store.open(empty); Issue.record("Expected file_empty") }
        catch let error as HyperDRError { #expect(error.code == "file_empty") }

        let unsupported = try environment.source("notes.txt", pngBytes)
        do { _ = try await store.open(unsupported); Issue.record("Expected unsupported_format") }
        catch let error as HyperDRError { #expect(error.code == "unsupported_format") }

        let disguised = try environment.source("actually-heic.jpg", heicBytes)
        do { _ = try await store.open(disguised); Issue.record("Expected input_extension_mismatch") }
        catch let error as HyperDRError {
            #expect(error.code == "input_extension_mismatch")
            #expect(error.message.contains(".heic"))
        }

        do { _ = try await store.session(SessionID(rawValue: "../../etc")); Issue.record("Expected invalid_options") }
        catch let error as HyperDRError { #expect(error.code == "invalid_options") }
    }

    @Test func cleanupExpiresIdleSessionsButProtectsOpenAndPendingExports() async throws {
        let environment = try TestEnvironment()
        let store = environment.store(ttl: .seconds(60))
        let idle = try await store.open(try environment.source("idle.png"))
        await store.close(idle.id)
        let open = try await store.open(try environment.source("open.png"))
        let exporting = try await store.open(try environment.source("exporting.png"))
        let (exportID, exportDirectory) = try await store.prepareExport(exporting.id,
            options: ["encoding": .string("sdr-jpeg")])
        await store.close(exporting.id)

        let future = Date().addingTimeInterval(120)
        #expect(await store.cleanupExpired(now: future) == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(idle.id).path))
        #expect(FileManager.default.fileExists(atPath: environment.sessionDirectory(open.id).path))
        #expect(FileManager.default.fileExists(atPath: environment.sessionDirectory(exporting.id).path))
        #expect(FileManager.default.fileExists(atPath: exportDirectory.path))
        do { _ = try await store.session(idle.id); Issue.record("Expected session_expired") }
        catch let error as HyperDRError { #expect(error.code == "session_expired") }

        await store.close(open.id)
        #expect(await store.cleanupExpired(now: future) == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(open.id).path))

        await store.discardExport(exporting.id, export: exportID)
        #expect(await store.cleanupExpired(now: future) == 1)
        #expect(!FileManager.default.fileExists(atPath: environment.sessionDirectory(exporting.id).path))
    }

    @Test func exportsPublishAtomicallyAndFilterByCurrentDigest() async throws {
        let environment = try TestEnvironment()
        let source = try environment.source("photo.png")
        let store = environment.store()
        let session = try await store.open(source)

        func publish(_ name: String, bytes: [UInt8]) async throws -> (ExportRecord, URL) {
            let (id, directory) = try await store.prepareExport(session.id,
                options: ["encoding": .string("sdr-jpeg")])
            let output = directory.appendingPathComponent(name)
            try Data(bytes).write(to: output)
            let report = ConvertReport(json: Data("{}".utf8), files: [ReportFile(
                input: source.path, output: output.path, success: true, skipped: false,
                message: "", width: 1, height: 1)])
            let record = try await store.publishExport(session.id, export: id, report: report)
            #expect(record.id == id)
            #expect(record.name == name)
            #expect(record.byteCount == Int64(bytes.count))
            #expect(!FileManager.default.fileExists(atPath:
                directory.appendingPathComponent("pending.json").path))
            #expect(FileManager.default.fileExists(atPath:
                directory.appendingPathComponent("result.json").path))
            return (record, output)
        }

        let (firstRecord, firstURL) = try await publish("first.jpg", bytes: [1, 2, 3])
        #expect(try await store.resultURL(session.id, export: firstRecord.id) == firstURL)
        #expect(try await store.resultURL(session.id, export: nil) == firstURL)
        let (secondRecord, secondURL) = try await publish("second.heic", bytes: [4, 5, 6, 7])
        let records = await store.exports(for: session.id)
        #expect(records.count == 2)
        #expect(records.first?.id == secondRecord.id)
        #expect(try await store.resultURL(session.id, export: nil) == secondURL)

        let (discardID, discardDirectory) = try await store.prepareExport(session.id, options: [:])
        await store.discardExport(session.id, export: discardID)
        #expect(!FileManager.default.fileExists(atPath: discardDirectory.path))

        let luts = try await store.resourceDirectory(session.id, .luts)
        let rawProfiles = try await store.resourceDirectory(session.id, .rawProfiles)
        #expect(luts.lastPathComponent == "luts")
        #expect(rawProfiles.lastPathComponent == "raw-profiles")
        #expect(FileManager.default.fileExists(atPath: luts.path))

        let changed = pngBytes + [0x09]
        try Data(changed).write(to: source)
        await store.close(session.id)
        let refreshed = try await store.session(session.id)
        #expect(refreshed.sha256 == sha256(changed))
        #expect(await store.exports(for: session.id).isEmpty)
        do { _ = try await store.resultURL(session.id, export: firstRecord.id); Issue.record("Expected source_missing") }
        catch let error as HyperDRError { #expect(error.code == "source_missing") }
    }

    @Test func decodeCachePrunesOldestAndOverBudgetFiles() async throws {
        let environment = try TestEnvironment()
        let store = environment.store(maxAge: 3600, maxBytes: 10)
        let cache = environment.cache.appendingPathComponent("decode-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let now = Date()
        let files: [(String, Int, TimeInterval)] = [("old.bin", 8, -7200), ("a.bin", 8, -10), ("b.bin", 8, -5)]
        for (name, size, age) in files {
            let url = cache.appendingPathComponent(name)
            try Data(repeating: 0x5a, count: size).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(age)], ofItemAtPath: url.path)
        }
        let removed = await store.trimDecodeCache(now: now)
        #expect(removed == 2)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("old.bin").path))
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("a.bin").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("b.bin").path))
    }
}

extension SessionStoreTests {
    @Test(.timeLimit(.minutes(1))) func restoreRefreshesStaleBookmarkAfterMove() async throws {
        let environment = try TestEnvironment()
        let store = environment.store()
        let source = try environment.source("before.png")
        let photo = try await store.open(source)
        await store.close(photo.id)
        let manifest = environment.sessionDirectory(photo.id).appendingPathComponent("session.json")
        let before = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        let base64 = try #require(before["sourceBookmark"] as? String)
        let bookmark = try #require(Data(base64Encoded: base64))
        let moved = source.deletingLastPathComponent().appendingPathComponent("after.png")
        try FileManager.default.moveItem(at: source, to: moved)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        print("review restore moved bookmark: stale=\(stale), resolved=\(resolved.lastPathComponent)")
        #expect(stale)
        let restoredStore = environment.store()
        guard case .restored(let restored) = await restoredStore.restoreLastOutcome() else {
            Issue.record("Moved source could not restore"); return
        }
        #expect(restored.id == photo.id)
        #expect(restored.sourceURL.path == moved.resolvingSymlinksInPath().path)
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        #expect(after["sourceBookmark"] as? String != before["sourceBookmark"] as? String)
        await restoredStore.close(photo.id)
    }
}

private final class ReviewRestoreAccess: SecurityScopedAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private var onStart: (@Sendable () -> Void)?
    func arm(_ callback: @escaping @Sendable () -> Void) { lock.withLock { onStart = callback } }
    func startAccessing(_ url: URL) -> Bool {
        let callback = lock.withLock { startCount += 1; return onStart }
        callback?()
        return true
    }
    func stopAccessing(_ url: URL) { lock.withLock { stopCount += 1 } }
    var counts: (Int, Int) { lock.withLock { (startCount, stopCount) } }
}

extension SessionStoreTests {
    @Test(.timeLimit(.minutes(1))) func reviewCancellationDuringRestoreMustReleaseItsOnlyLease() async throws {
        let environment = try TestEnvironment()
        let access = ReviewRestoreAccess()
        let store = SessionStore(configuration: KitConfiguration(supportDirectory: environment.support,
            cacheDirectory: environment.cache, sessionTTL: .seconds(3600)), formats: environment.formats,
            decodeCacheMaxAge: 3600, decodeCacheMaxBytes: 1 << 20, access: access)
        let photo = try await store.open(try environment.source("during-restore.png"))
        await store.close(photo.id)
        let (start, signal) = AsyncStream.makeStream(of: Void.self)
        let restoration = Task {
            for await _ in start { break }
            return await store.restoreLastOutcome()
        }
        access.arm { restoration.cancel() }
        signal.yield(); signal.finish()
        let outcome = await restoration.value
        guard case .unavailable(let error) = outcome else { Issue.record("Expected cancellation"); return }
        #expect(error.code == "cancelled")
        print("review restore cancelled at lease acquisition: starts/stops=\(access.counts)")
        #expect(access.counts.0 == access.counts.1, "The only restore caller left without a PhotoSession but still owns a lease")
        await store.close(photo.id)
        print("review restore after explicit cleanup: starts/stops=\(access.counts)")
    }
}

extension SessionStoreTests {
    @Test func publishedVersionsSurviveStoreRecreationAndRejectMissingFailedOrEscapingReports() async throws {
        let env = try TestEnvironment()
        let store = env.store()
        let source = try env.source("versions.png")
        let photo = try await store.open(source)
        var published: [(ExportID, URL)] = []
        for name in ["photo.jpg", "photo.heic", "photo.avif", "photo.tif"] {
            let (id, directory) = try await store.prepareExport(photo.id, options: [:])
            let output = directory.appendingPathComponent(name)
            try Data(name.utf8).write(to: output)
            let report = ConvertReport(json: Data("{}".utf8), files: [ReportFile(input: source.path,
                output: output.path, success: true, skipped: false, message: "", width: 1, height: 1)])
            _ = try await store.publishExport(photo.id, export: id, report: report)
            published.append((id, output))
        }
        await store.close(photo.id)
        let recreated = env.store()
        _ = try await recreated.session(photo.id)
        #expect(await recreated.exports(for: photo.id).count == 4)
        for (id, url) in published {
            #expect(try await recreated.resultURL(photo.id, export: id) == url)
            #expect(try Data(contentsOf: url) == Data(url.lastPathComponent.utf8))
        }
        for mode in ["empty-report", "missing", "failed", "outside"] {
            let (id, directory) = try await recreated.prepareExport(photo.id, options: [:])
            let output = mode == "outside" ? env.root.appendingPathComponent("outside.jpg") : directory.appendingPathComponent("result.jpg")
            if mode != "missing" { try Data([9]).write(to: output) }
            let report = ConvertReport(json: Data("{}".utf8), files: [ReportFile(input: source.path,
                output: output.path, success: mode != "failed", skipped: false, message: "", width: 1, height: 1)])
            let supplied = mode == "empty-report" ? ConvertReport(json: Data("{}".utf8), files: []) : report
            do { _ = try await recreated.publishExport(photo.id, export: id, report: supplied); Issue.record("Invalid report published: \(mode)") }
            catch let error as HyperDRError { #expect(error.code == (mode == "outside" ? "invalid_options" : "internal_error")) }
            await recreated.discardExport(photo.id, export: id)
            #expect(await recreated.exports(for: photo.id).count == 4)
        }
        await recreated.close(photo.id)
    }

    @Test func cleanupIgnoresOldDirectoriesWhoseNamesAreNotSessionIDs() async throws {
        let env = try TestEnvironment()
        let store = env.store(ttl: .seconds(1))
        let photo = try await store.open(try env.source("idle.png"))
        await store.close(photo.id)
        let stray = env.support.appendingPathComponent("sessions/not-a-session")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let marker = stray.appendingPathComponent("keep-me")
        try Data([42]).write(to: marker)
        #expect(await store.cleanupExpired(now: Date().addingTimeInterval(100)) == 1)
        #expect(try Data(contentsOf: marker) == Data([42]))
    }
}

extension SessionStoreTests {
    @Test func sessionIdentifiersRejectTraversalAndMalformedHex() async throws {
        let env = try TestEnvironment()
        let store = env.store()
        for raw in ["", "..", "../etc", String(repeating: "z", count: 32), String(repeating: "0", count: 31)] {
            let id = SessionID(rawValue: raw)
            do { _ = try await store.session(id); Issue.record("Invalid session ID accepted: \(raw)") }
            catch let error as HyperDRError { #expect(error.code == "invalid_options") }
        }
        do { _ = try await store.session(SessionID(rawValue: String(repeating: "0", count: 32))); Issue.record("Missing session accepted") }
        catch let error as HyperDRError { #expect(error.code == "session_expired") }
    }
}

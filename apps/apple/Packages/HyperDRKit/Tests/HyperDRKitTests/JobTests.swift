import Foundation
import Darwin
import CoreGraphics
import ImageIO
import HyperDREngine
import Testing
@testable import HyperDRKit

private final class JobEnvironment: Sendable {
    let root: URL
    let configuration: KitConfiguration
    let sessions: SessionStore
    let resolver: OptionResolver
    init(timeout: Duration = .seconds(30),
         openExportLeaf: @escaping SessionStore.OpenExportLeaf = { openat($0, $1, $2) }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-jobs-\(UUID())")
        configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache"), jobTimeout: timeout)
        let schema = try Engine.schema()
        sessions = SessionStore(configuration: configuration, formats: try InputFormats(schema: schema),
            decodeCacheMaxAge: 7 * 24 * 60 * 60, decodeCacheMaxBytes: 4 << 30, openExportLeaf: openExportLeaf)
        resolver = OptionResolver(schema: schema, knownModels: [:], maxEdgeCeiling: 2048)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func photo() async throws -> PhotoSession {
        let source = root.appendingPathComponent("photo.png")
        try Data([137,80,78,71,13,10,26,10] + [UInt8](repeating: 0, count: 64)).write(to: source)
        return try await sessions.open(source)
    }
    func runner(probe: @escaping @Sendable (URL) async throws -> (Int, Int) = { _ in (800, 600) },
                convert: @escaping JobRunner.Converter = fakeConversion) -> JobRunner {
        JobRunner(configuration: configuration, sessions: sessions, resolver: resolver,
            probe: probe, convert: convert)
    }
}

private struct SwapExportAncestorAccess: SecurityScopedAccess {
    let original: URL
    let outside: URL
    func startAccessing(_ url: URL) -> Bool {
        do {
            try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("saved"))
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        } catch { Issue.record("Unable to arrange source replacement: \(error)") }
        return true
    }
    func stopAccessing(_ url: URL) {}
}

@Suite(.timeLimit(.minutes(1))) struct ExportTargetRaceTests {
    @Test func sourceAncestorReplacementMustNotCopyAnOutsideFile() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let source = try await env.sessions.resultURL(photo.id, export: ticket.export)
        let outside = env.root.appendingPathComponent("outside")
        let destination = env.root.appendingPathComponent("destination")
        for directory in [outside, destination] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let privateBytes = Data("OUTSIDE SECRET, NOT THE EXPORT".utf8)
        try privateBytes.write(to: outside.appendingPathComponent(source.lastPathComponent))
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SwapExportAncestorAccess(original: source.deletingLastPathComponent(), outside: outside))
        do {
            let saved = try await target.save(session: photo.id, export: ticket.export, oneOff: destination)
            let copied = try Data(contentsOf: saved.url)
            print("K3 source ancestor replacement: copiedOutside=\(copied == privateBytes)")
            #expect(copied == Data([1,2,3]))
        } catch let error as HyperDRError {
            #expect(error.code == "source_missing" || error.code == "internal_error")
        }
    }
    @Test func failureCleanupMustNotUnlinkAReplacementFile() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let destination = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let replacement = destination.appendingPathComponent("photo.tif")
        let userBytes = Data("USER REPLACEMENT".utf8)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { _, _, _ in
                do {
                    if FileManager.default.fileExists(atPath: replacement.path) {
                        try FileManager.default.moveItem(at: replacement,
                            to: destination.appendingPathComponent("displaced-own-file.tif"))
                    }
                    try userBytes.write(to: replacement, options: .withoutOverwriting)
                } catch { Issue.record("Unable to arrange destination replacement: \(error)") }
                errno = EIO
                return -1
            })
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export, oneOff: destination) } == "export_folder_unwritable")
        let exists = FileManager.default.fileExists(atPath: replacement.path)
        print("K3 injected EIO cleanup: replacementExists=\(exists)")
        try #require(exists)
        #expect(try Data(contentsOf: replacement) == userBytes)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains { $0.hasPrefix(".hyperdr-export-") })
    }
}

@Suite(.timeLimit(.minutes(1))) struct ExportTargetTests {
    @Test func copiesAreExclusiveAndOneOffDoesNotReplaceTheRememberedFolder() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        #expect(await target.folder.ready == false)
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export) } == "export_folder_unset")
        let fixed = env.root.appendingPathComponent("fixed")
        let once = env.root.appendingPathComponent("once")
        for directory in [fixed, once] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        _ = try await target.setFolder(fixed)
        let existing = fixed.appendingPathComponent("photo.tif")
        try Data([9]).write(to: existing)
        async let a = target.save(session: photo.id, export: ticket.export)
        async let b = target.save(session: photo.id, export: ticket.export)
        let saved = try await [a, b]
        #expect(Set(saved.map(\.name)) == ["photo (2).tif", "photo (3).tif"])
        #expect(try Data(contentsOf: existing) == Data([9]))
        for output in saved { #expect(try Data(contentsOf: output.url) == Data([1,2,3])) }
        let one = try await target.save(session: photo.id, export: ticket.export, oneOff: once)
        #expect(one.url.deletingLastPathComponent().lastPathComponent == "once")
        #expect(await target.folder.label.hasSuffix("/fixed"))
        let restored = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        #expect(await restored.folder.ready)
        #expect(await restored.folder.label.hasSuffix("/fixed"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixed.path).count == 3)
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export,
            oneOff: env.configuration.supportDirectory) } == "export_folder_inside_workspace")
        let alias = env.root.appendingPathComponent("save-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: once)
        _ = try await target.setFolder(alias)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: env.configuration.supportDirectory)
        #expect(await target.folder.ready)
        #expect(await target.folder.label.hasSuffix("/once"))
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export, oneOff: alias) } == "export_folder_inside_workspace")
    }
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
private func fakeConversion(_ request: EngineRequest,
                            _ events: @escaping @Sendable (ConvertEvent) -> Void) async throws -> ConvertReport {
    for index in 0..<50 {
        let data = try JSONSerialization.data(withJSONObject: ["phase": "encode", "path": "", "fraction": Double(index)/50, "text": "\(index)\n"])
        events(try JSONDecoder().decode(ConvertEvent.self, from: data))
    }
    let output = URL(fileURLWithPath: request.command["output"]!.stringValue!).appendingPathComponent("photo.tif")
    try Data([1, 2, 3]).write(to: output)
    return ConvertReport(json: Data("{}".utf8), files: [ReportFile(input: "", output: output.path,
        success: true, skipped: false, message: "", width: 800, height: 600)])
}
private func eventually(timeout: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
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
    @Test func realEngineCancellationFinishesWithinTwoHundredMilliseconds() async throws {
        let env = try JobEnvironment()
        let source = env.root.appendingPathComponent("large.png")
        let width = 2600, height = 2000
        let pixels = Data(repeating: 128, count: width * height * 4)
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        let kit = try await HyperDRKit(configuration: env.configuration)
        let photo = try await kit.sessions.open(source)
        let ticket = try await kit.jobs.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-jpeg")]))
        var cancelledAt: ContinuousClock.Instant?
        for await event in kit.jobs.events(ticket.job) {
            if case .progress(let progress) = event, progress.phase == "decode", cancelledAt == nil {
                cancelledAt = .now
                #expect(await kit.jobs.cancel(ticket.job))
            }
            if case .finished(let summary) = event {
                let start = try #require(cancelledAt)
                #expect(start.duration(to: .now) < .milliseconds(200))
                #expect(summary.cancelled && summary.failure?.code == "cancelled")
            }
        }
        #expect(await kit.sessions.exports(for: photo.id).isEmpty)
        let folder = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports/\(ticket.export)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await kit.sessions.close(photo.id)
    }
    @Test func logBoundsUseAbsoluteUnicodeScalarOffsets() {
        var log = JobLog(limit: 4)
        log.append("😀e\u{301}ab")
        #expect(log.end == 5); #expect(log.start == 1)
        #expect(log.read(0).truncated)
        #expect(log.read(0).text == "e\u{301}ab")
        #expect(log.read(1).truncated)
        #expect(log.read(999).text.isEmpty)
        #expect(log.read(Int.min).truncated && log.read(Int.min).text == "e\u{301}ab")
        log.append(""); #expect(log.end == 5)
        var short = JobLog(limit: 10)
        short.append("brief\n")
        #expect(!short.read(0).truncated && short.read(0).text == "brief\n")
        #expect(short.read(-1).truncated)
    }
    @Test func publicationPrecedesTerminalAndProgressRemainsOrdered() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner(convert: { request, events in
            try await Task.sleep(for: .milliseconds(30))
            return try await fakeConversion(request, events)
        })
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]))
        #expect(ticket.argv.first == "HyperDR")
        var progress: [Double] = []
        for await event in runner.events(ticket.job) {
            if case .progress(let value) = event { progress.append(value.fraction) }
            if case .finished(let result) = event {
                #expect(result.done); #expect(result.failure == nil)
                #expect(try await env.sessions.resultURL(photo.id, export: ticket.export).lastPathComponent == "photo.tif")
            }
        }
        #expect(progress == (0..<50).map { Double($0)/50 })
        let snapshot = try #require(await runner.read(ticket.job, offset: 0))
        #expect(snapshot.text == (0..<50).map { "\($0)\n" }.joined())
        #expect(await runner.cancel(ticket.job) == false)
        #expect(await runner.job(for: photo.id) == nil)
        var terminals = 0
        for await event in runner.events(ticket.job) { if case .finished = event { terminals += 1 } }
        #expect(terminals == 1)
    }
    @Test func cancellationDiscardsBeforeTerminalAndAdmitsAnotherJob() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner(convert: { _, _ in try await Task.sleep(for: .seconds(30)); throw CancellationError() })
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions()) } == "convert_in_progress")
        let start = ContinuousClock.now
        #expect(await runner.cancel(ticket.job))
        try #require(await eventually(timeout: .milliseconds(200)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        #expect(ContinuousClock.now - start < .milliseconds(200))
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
        let folder = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports/\(ticket.export)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let next = try await runner.start(session: photo.id, options: EditOptions())
        #expect(next.job != ticket.job); #expect(await runner.read(ticket.job, offset: 0) == nil)
        _ = await runner.cancel(next.job)
        #expect(await eventually { await runner.read(next.job, offset: 0)?.summary.done == true })
    }
    @Test func timeoutDiscardsAndReportsTerminal() async throws {
        let env = try JobEnvironment(timeout: .milliseconds(20))
        let photo = try await env.photo()
        let runner = env.runner(convert: { _, _ in try await Task.sleep(for: .seconds(30)); throw CancellationError() })
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let result = try #require(await runner.read(ticket.job, offset: 0))
        #expect(result.summary.timedOut); #expect(result.summary.failure?.code == "convert_timeout")
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
    }
    @Test func invalidFrameOptionsFailBeforeCreatingAnyExportDirectory() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let invalid = ExportFrame(spec: ["schema": .string("invalid")])
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions(), frame: invalid) } == "invalid_options")
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions(["frame": .object([:])])) } == "invalid_options")
        let frame = ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")], overlayPNG: Data([1]))
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions(), frame: frame) } == "invalid_options")
        let exports = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []
        #expect(contents.isEmpty)
    }
    @Test func frameIsWrittenAsAReplayableFile() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions(),
            frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")]))
        let index = try #require(ticket.argv.firstIndex(of: "--frame"))
        #expect(FileManager.default.fileExists(atPath: ticket.argv[index+1]))
        #expect(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        #expect(await runner.read(ticket.job, offset: 0)?.summary.failure == nil)
    }
    @Test func admissionAlsoCoversSuspendingFramePreparation() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let (stream, signal) = AsyncStream.makeStream(of: Void.self)
        let runner = env.runner(probe: { _ in
            signal.yield(())
            try await Task.sleep(for: .milliseconds(100))
            return (800, 600)
        })
        let first = Task { try await runner.start(session: photo.id, options: EditOptions(), frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])) }
        for await _ in stream { break }
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions()) } == "convert_in_progress")
        let ticket = try await first.value
        #expect(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
    }

    @Test func failurePreservesPublishedVersionsAndCleansTheFailedVersion() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let good = env.runner()
        let first = try await good.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await good.read(first.job, offset: 0)?.summary.done == true })
        let bad = env.runner(convert: { _, _ in
            ConvertReport(json: Data("{}".utf8), files: [])
        })
        let second = try await bad.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await bad.read(second.job, offset: 0)?.summary.done == true })
        #expect(await bad.read(second.job, offset: 0)?.summary.failure?.code == "internal_error")
        #expect(await env.sessions.exports(for: photo.id).map(\.id) == [first.export])
        #expect(try Data(contentsOf: await env.sessions.resultURL(photo.id, export: first.export)) == Data([1,2,3]))
    }

    @Test func cancellingPreparationReleasesAdmissionAndAllocatesNoVersion() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let (stream, signal) = AsyncStream.makeStream(of: Void.self)
        let runner = env.runner(probe: { _ in
            signal.yield(())
            try await Task.sleep(for: .seconds(30)); return (800, 600)
        })
        let preparation = Task { try await runner.start(session: photo.id, options: EditOptions(),
            frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])) }
        for await _ in stream { break }
        preparation.cancel()
        #expect(await failureCode { _ = try await preparation.value } == "cancelled")
        let next = try await runner.start(session: photo.id, options: EditOptions())
        #expect(await eventually { await runner.read(next.job, offset: 0)?.summary.done == true })
        #expect(await env.sessions.exports(for: photo.id).count == 1)
    }

    @Test func disposingOnePendingVersionDoesNotUnpinAnother() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let a = try await env.sessions.prepareExport(photo.id, options: [:])
        let b = try await env.sessions.prepareExport(photo.id, options: [:])
        await env.sessions.close(photo.id)
        await env.sessions.discardExport(photo.id, export: a.id)
        #expect(await env.sessions.cleanupExpired(now: Date().addingTimeInterval(1_000_000)) == 0)
        #expect(FileManager.default.fileExists(atPath: b.directory.path))
        await env.sessions.discardExport(photo.id, export: b.id)
        #expect(await env.sessions.cleanupExpired(now: Date().addingTimeInterval(1_000_000)) == 1)
    }
}

private final class StagingInodeSwap: @unchecked Sendable {
    let destination: URL
    private let lock = NSLock()
    private var swapped = false
    init(_ destination: URL) { self.destination = destination }
    func read(_ fd: Int32, _ bytes: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        if lock.withLock({ let first = !swapped; swapped = true; return first }) {
            do {
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: destination.path)
                    .first { $0.hasPrefix(".hyperdr-export-") })
                let entry = destination.appendingPathComponent(name)
                var directory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: entry.path, isDirectory: &directory)
                let leaf: URL
                if directory.boolValue {
                    let permissions = try FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions] as? NSNumber
                    #expect(permissions?.intValue == 0o700)
                    leaf = entry.appendingPathComponent("payload")
                } else { leaf = entry }
                // Same-user fault injection deliberately enters the private
                // directory, testing the extra inode comparison as well.
                try FileManager.default.moveItem(at: leaf, to: destination.appendingPathComponent("displaced-inode"))
                try Data("REPLACED STAGING BYTES".utf8).write(to: leaf, options: .withoutOverwriting)
            } catch { Issue.record("Unable to replace staging inode: \(error)") }
        }
        return Darwin.read(fd, bytes, count)
    }
}

private final class FIFOLeafSwap: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var rescued: Bool { lock.withLock { finished } }
    func open(_ directory: Int32, _ name: String, _ flags: Int32) -> Int32 {
        guard unlinkat(directory, name, 0) == 0, mkfifoat(directory, name, 0o600) == 0 else {
            Issue.record("Unable to replace validated source with FIFO")
            return -1
        }
        let rescueDirectory = dup(directory)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(600)) { [self] in
            // Rescue the old blocking implementation. O_NONBLOCK means the
            // fixed implementation cannot leave this writer stuck instead.
            let writer = openat(rescueDirectory, name, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { Darwin.close(writer) }
            Darwin.close(rescueDirectory)
            lock.withLock { finished = true }
        }
        return openat(directory, name, flags)
    }
}

extension ExportTargetRaceTests {
    @Test func publicationRejectsAReplacedStagingInode() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let destination = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let swap = StagingInodeSwap(destination)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { swap.read($0, $1, $2) })
        do {
            let saved = try await target.save(session: photo.id, export: ticket.export, oneOff: destination)
            let bytes = try Data(contentsOf: saved.url)
            print("K3 staging inode: publishedReplacement=\(bytes == Data("REPLACED STAGING BYTES".utf8))")
            #expect(bytes == Data([1,2,3]), "Only the written/fsynced inode may be published")
        } catch let error as HyperDRError {
            #expect(error.code == "export_folder_unwritable")
            #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("photo.tif").path))
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: destination.path)).contains { $0.hasPrefix(".hyperdr-export-") })
    }
    @Test func sourceLeafFIFOReplacementCannotBlockTheSessionActor() async throws {
        let fault = FIFOLeafSwap()
        let env = try JobEnvironment(openExportLeaf: { fault.open($0, $1, $2) })
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let start = ContinuousClock.now
        #expect(await failureCode { _ = try await env.sessions.exportFile(photo.id, export: ticket.export) } == "source_missing")
        let elapsed = start.duration(to: .now)
        print("K3 FIFO replacement: elapsed=\(elapsed)")
        #expect(elapsed < .milliseconds(200))
        #expect(await eventually { fault.rescued })
    }
}

private final class OuterStagingSwap: @unchecked Sendable {
    let destination: URL
    let moved: URL
    let replacement = Data("OUTER DIRECTORY REPLACEMENT".utf8)
    private let lock = NSLock()
    private var swapped = false
    private(set) var originalName: String?
    init(_ destination: URL) {
        self.destination = destination
        moved = destination.appendingPathComponent("relocated-private-staging")
    }
    func read(_ fd: Int32, _ bytes: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        if lock.withLock({ let first = !swapped; swapped = true; return first }) {
            do {
                let name = try #require(FileManager.default.contentsOfDirectory(atPath: destination.path)
                    .first { $0.hasPrefix(".hyperdr-export-") })
                originalName = name
                let entry = destination.appendingPathComponent(name)
                try FileManager.default.moveItem(at: entry, to: moved)
                try replacement.write(to: entry, options: .withoutOverwriting)
            } catch { Issue.record("Unable to replace staging directory name: \(error)") }
        }
        return Darwin.read(fd, bytes, count)
    }
}
extension ExportTargetRaceTests {
    @Test func movingThePrivateStagingDirectoryCannotRedirectPublicationOrCleanup() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let destination = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let swap = OuterStagingSwap(destination)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { swap.read($0, $1, $2) })
        let saved = try await target.save(session: photo.id, export: ticket.export, oneOff: destination)
        #expect(try Data(contentsOf: saved.url) == Data([1,2,3]))
        #expect(!FileManager.default.fileExists(atPath: swap.moved.path))
        let name = try #require(swap.originalName)
        #expect(try Data(contentsOf: destination.appendingPathComponent(name)) == swap.replacement,
            "Cleanup must preserve somebody else's replacement at the old outer name")
    }
}

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
    let resolver: OptionResolver
    init(timeout: Duration = .seconds(30), historyLimit: Int = 20,
         openExportLeaf: @escaping SessionStore.OpenExportLeaf = { openat($0, $1, $2) }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-jobs-\(UUID())")
        configuration = KitConfiguration(supportDirectory: root.appendingPathComponent("support"),
            cacheDirectory: root.appendingPathComponent("cache"), exportHistoryLimit: historyLimit, jobTimeout: timeout)
        let schema = try Engine.schema()
        sessions = SessionStore(configuration: configuration, formats: try InputFormats(schema: schema),
            decodeCacheMaxAge: 7 * 24 * 60 * 60, decodeCacheMaxBytes: 4 << 30, openExportLeaf: openExportLeaf)
        resolver = OptionResolver(schema: schema, knownModels: [:], maxEdgeCeiling: 2048)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func photo(_ name: String = "photo.png") async throws -> PhotoSession {
        let source = root.appendingPathComponent(name)
        try Data([137,80,78,71,13,10,26,10] + [UInt8](repeating: 0, count: 64)).write(to: source)
        return try await sessions.open(source)
    }
    func runner(probe: @escaping @Sendable (URL) async throws -> (Int, Int) = { _ in (800, 600) },
                convert: @escaping JobRunner.Converter = fakeConversion,
                beforePublish: @escaping @Sendable () async -> Void = {},
                exportTarget: ExportTarget? = nil) -> JobRunner {
        JobRunner(configuration: configuration, sessions: sessions, resolver: resolver,
            probe: probe, convert: convert, beforePublish: beforePublish, exportTarget: exportTarget)
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

@Suite(.timeLimit(.minutes(1))) struct ExportTargetStagingTests {
    private func finishedExport(_ env: JobEnvironment) async throws -> (PhotoSession, JobTicket) {
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        return (photo, ticket)
    }
    private func leftovers(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".hyperdr-export-") }
    }

    /// K3-K4-K6 rereview §4: a staging directory that cannot be opened, or
    /// that fails the owner/0700 check, is removed rather than left hidden in
    /// the user's folder.
    @Test func failedStagingChecksLeaveNoPrivateDirectory() async throws {
        let env = try JobEnvironment()
        let (photo, ticket) = try await finishedExport(env)
        let destination = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var unopenable = ExportTarget.CopyHooks()
        unopenable.openStaging = { _, _ in errno = EACCES; return -1 }
        // Opens the destination itself: a directory that is not 0700.
        var wrongDirectory = ExportTarget.CopyHooks()
        wrongDirectory.openStaging = { parent, _ in openat(parent, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        for hooks in [unopenable, wrongDirectory] {
            let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
                access: SystemSecurityScopedAccess(), hooks: hooks)
            #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export,
                oneOff: destination) } == "export_folder_unwritable")
            #expect(try leftovers(destination) == [])
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == [])
    }

    /// K3-K4-K6 rereview §4: once the file is published, a failed folder sync
    /// is a successful save that says the sync was not confirmed, not
    /// `export_folder_unwritable` (a retry would save "photo (2).tif").
    @Test func folderSyncFailureAfterPublishingIsASavedExport() async throws {
        let env = try JobEnvironment()
        let (photo, ticket) = try await finishedExport(env)
        let destination = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var hooks = ExportTarget.CopyHooks()
        hooks.syncFolder = { _ in errno = EIO; return -1 }
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        let saved = try await target.save(session: photo.id, export: ticket.export, oneOff: destination)
        #expect(saved.syncConfirmed == false)
        #expect(saved.name == "photo.tif")
        #expect(try Data(contentsOf: saved.url) == Data([1,2,3]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["photo.tif"])
        let normal = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        #expect(try await normal.save(session: photo.id, export: ticket.export, oneOff: destination).syncConfirmed)
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
    @Test func realEngineCancellationDiscardsBeforeTerminal() async throws {
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
        let engine = try await Engine()
        let photo = try await env.sessions.open(source)
        let gate = BlockingJobGate()
        defer { gate.release() }
        let runner = env.runner(convert: { request, events in
            try await engine.convert(request, events: { event in
                events(event)
                if event.phase == "decode" { gate.waitForRelease() }
            })
        })
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-jpeg")]))
        // The real C conversion remains in its decode callback until cancel()
        // has propagated to its work task. It cannot naturally win this race.
        try #require(await eventually(timeout: .seconds(10)) { gate.entered })
        let started = ContinuousClock.now
        #expect(await runner.cancel(ticket.job))
        gate.release()
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let summary = try #require(await runner.read(ticket.job, offset: 0)?.summary)
        print("Native cancellation/cleanup latency (diagnostic): \(started.duration(to: .now))")
        #expect(summary.cancelled && summary.failure?.code == "cancelled")
        #expect(!gate.didTimeOut)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
        let folder = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports/\(ticket.export)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await env.sessions.close(photo.id)
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
        // test_the_log_is_served_incrementally_by_offset: a non-zero offset
        // inside the retained range returns the suffix; `end` returns nothing.
        #expect(short.read(3).text == "ef\n" && !short.read(3).truncated)
        #expect(short.read(short.end).text.isEmpty && !short.read(short.end).truncated)
        #expect(log.read(2).text == "\u{301}ab")   // `truncated` reports the dropped head
        #expect(log.read(log.end).text.isEmpty)
    }
    /// The runner hands back `end` as the next offset; reading from it again
    /// returns nothing until more is logged.
    @Test func runnerLogOffsetResumesAtTheEnd() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let first = try #require(await runner.read(ticket.job, offset: 0))
        #expect(!first.text.isEmpty)
        #expect(first.offset == first.logStart + first.text.unicodeScalars.count)
        let next = try #require(await runner.read(ticket.job, offset: first.offset))
        #expect(next.text.isEmpty && !next.truncated && next.offset == first.offset)
    }
    @Test func publicationPrecedesTerminalAndProgressRemainsOrdered() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let gate = TestStepGate()
        defer { gate.release() }
        let runner = env.runner(convert: { request, events in
            await gate.wait()
            return try await fakeConversion(request, events)
        })
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]))
        #expect(ticket.argv.first == "HyperDR")
        var progress: [Double] = []
        var published = false
        let stream = runner.events(ticket.job) // Synchronous subscription before any callbacks.
        gate.release()
        for await event in stream {
            if case .progress(let value) = event { progress.append(value.fraction) }
            if case .publishing = event { published = true }
            if case .finished(let result) = event {
                #expect(published)
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
        let gates = [TestStepGate(), TestStepGate()], calls = Mutex(0)
        defer { gates.forEach { $0.release() } }
        let runner = env.runner(convert: { request, events in
            let index = calls.withLock { count in defer { count += 1 }; return count }
            await gates[min(index, 1)].wait(releaseOnCancel: true)
            try Task.checkCancellation()
            return try await fakeConversion(request, events)
        })
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { gates[0].entered })
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions()) } == "convert_in_progress")
        #expect(await runner.cancel(ticket.job))
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        #expect(gates[0].cancelled)
        #expect(await runner.read(ticket.job, offset: 0)?.summary.cancelled == true)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
        let folder = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports/\(ticket.export)")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let next = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { gates[1].entered })
        #expect(next.job != ticket.job); #expect(await runner.read(ticket.job, offset: 0) == nil)
        #expect(await runner.cancel(next.job))
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(next.job, offset: 0)?.summary.done == true })
        #expect(gates[1].cancelled)
    }
    @Test func timeoutDiscardsAndReportsTerminal() async throws {
        let env = try JobEnvironment(timeout: .milliseconds(20))
        let photo = try await env.photo()
        let gate = TestStepGate()
        defer { gate.release() }
        let runner = env.runner(convert: { request, events in
            await gate.wait(releaseOnCancel: true)
            try Task.checkCancellation()
            return try await fakeConversion(request, events)
        })
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
        let gate = TestStepGate()
        defer { gate.release() }
        let runner = env.runner(probe: { _ in await gate.wait(); return (800, 600) })
        let first = Task { try await runner.start(session: photo.id, options: EditOptions(), frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])) }
        try #require(await eventually(timeout: .seconds(10)) { gate.entered })
        #expect(await runner.activity == .preparing)
        #expect(await failureCode { _ = try await runner.start(session: photo.id, options: EditOptions()) } == "convert_in_progress")
        gate.release()
        let ticket = try await first.value
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
    }

    @Test func perFileFailuresPreserveCodesDetailsAndDiscardWork() async throws {
        for code in ["export_dimension_limit", "export_memory_budget", "export_failed", "raw_unsupported"] {
            let env = try JobEnvironment()
            let photo = try await env.photo()
            let data = Data("""
                {"input":"photo.png","output":"","success":false,"skipped":false,
                 "message":"Failed export","error_code":\(code == "export_failed" ? "null" : "\"\(code)\""),
                 "detail":"full error detail","error_detail":{"container":"dng","model":"Camera"}}
                """.utf8)
            let file = try JSONDecoder().decode(ReportFile.self, from: data)
            let runner = env.runner(convert: { _, _ in ConvertReport(json: data, files: [file]) })
            let ticket = try await runner.start(session: photo.id, options: EditOptions())
            try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
            let result = try #require(await runner.read(ticket.job, offset: 0))
            #expect(result.summary.failure?.code == code)
            #expect(result.summary.failure?.message == "Failed export")
            #expect(result.summary.failure?.messageDetail == "full error detail")
            #expect(result.summary.failure?.detail == .object(["container": .string("dng"), "model": .string("Camera")]))
            #expect(await env.sessions.exports(for: photo.id).isEmpty)
            let directory = env.configuration.supportDirectory.appendingPathComponent("sessions/\(photo.id)/exports")
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
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
        #expect(await bad.read(second.job, offset: 0)?.summary.failure?.code == "export_failed")
        #expect(await env.sessions.exports(for: photo.id).map(\.id) == [first.export])
        #expect(try Data(contentsOf: await env.sessions.resultURL(photo.id, export: first.export)) == Data([1,2,3]))
    }

    @Test func cancellingPreparationReleasesAdmissionAndAllocatesNoVersion() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let gate = TestStepGate()
        defer { gate.release() }
        let runner = env.runner(probe: { _ in
            await gate.wait(releaseOnCancel: true)
            try Task.checkCancellation()
            return (800, 600)
        })
        let preparation = Task { try await runner.start(session: photo.id, options: EditOptions(),
            frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])) }
        try #require(await eventually(timeout: .seconds(10)) { gate.entered })
        preparation.cancel()
        #expect(await failureCode { _ = try await preparation.value } == "cancelled")
        #expect(gate.cancelled)
        #expect(await runner.activity == .idle)
        let next = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(next.job, offset: 0)?.summary.done == true })
        #expect(await env.sessions.exports(for: photo.id).count == 1)
    }

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

extension JobTests {
    @Test func invalidSettingsLeaveThePublishedVersionAndJobUntouched() async throws {
        let env = try JobEnvironment()
        let photo = try await env.photo()
        let runner = env.runner()
        let unknown = JobID(rawValue: "unknown-job")
        #expect(await runner.cancel(unknown) == false)
        #expect(await runner.read(unknown, offset: 0) == nil)
        let good = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually { await runner.read(good.job, offset: 0)?.summary.done == true })
        let saved = try await env.sessions.resultURL(photo.id, export: good.export)
        #expect(await failureCode { _ = try await runner.start(session: photo.id,
            options: EditOptions(["contrast": .string("wrong-type")])) } == "invalid_options")
        #expect(await runner.read(good.job, offset: 0)?.summary.done == true)
        #expect(await env.sessions.exports(for: photo.id).map(\.id) == [good.export])
        #expect(try Data(contentsOf: saved) == Data([1,2,3]))
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
        #expect(folder.label == "…")
        #expect(folder.label != "/")
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
    private let flags = Mutex<Int32?>(nil)
    var observedNonblocking: Bool { flags.withLock { $0.map { $0 & O_NONBLOCK != 0 } ?? false } }
    func open(_ directory: Int32, _ name: String, _ requested: Int32) -> Int32 {
        guard unlinkat(directory, name, 0) == 0, mkfifoat(directory, name, 0o600) == 0 else {
            Issue.record("Unable to replace validated source with FIFO")
            return -1
        }
        flags.withLock { $0 = requested }
        // Prevent a regressed implementation hanging the test host: the
        // assertion below still fails when O_NONBLOCK was not requested.
        return openat(directory, name, requested | O_NONBLOCK)
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
        #expect(await failureCode { _ = try await env.sessions.exportFile(photo.id, export: ticket.export) } == "source_missing")
        #expect(fault.observedNonblocking, "Opening an untrusted export leaf must not wait for a FIFO writer")
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

@Suite(.timeLimit(.minutes(1))) struct M3JobContractTests {
    @Test func cancelAllWaitsForPreparationCleanup() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), gate = TestStepGate()
        defer { gate.release() }
        let runner = env.runner(probe: { _ in
            await gate.wait()
            try Task.checkCancellation(); return (800,600)
        })
        let start = Task { try await runner.start(session: photo.id, options: EditOptions(),
            frame: ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])) }
        try #require(await eventually(timeout: .seconds(10)) { gate.entered })
        #expect(await runner.activity == .preparing)
        let returned = Mutex(false)
        let stop = Task { await runner.cancelAll(); returned.withLock { $0 = true } }
        try #require(await eventually(timeout: .seconds(10)) {
            let waiters = await runner.cancelAllWaiterCount
            return gate.cancelled && waiters == 1
        })
        #expect(!returned.withLock { $0 })
        #expect(await runner.activity == .preparing)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
        gate.release()
        await stop.value
        #expect(await failureCode { _ = try await start.value } == "cancelled")
        #expect(await runner.cancelAllWaiterCount == 0)
        #expect(await runner.activity == .idle)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
    }

    @Test func cancelAllDrainsRunningAndWaitsForCommit() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), runningGate = TestStepGate()
        defer { runningGate.release() }
        let runner = env.runner(convert: { request, events in
            await runningGate.wait()
            try Task.checkCancellation()
            return try await fakeConversion(request, events)
        })
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { runningGate.entered })
        #expect(await runner.activity == .running(ticket.job))
        let runningStop = Task { await runner.cancelAll() }
        try #require(await eventually(timeout: .seconds(10)) {
            let waiters = await runner.cancelAllWaiterCount
            return runningGate.cancelled && waiters == 1
        })
        #expect(await runner.activity == .running(ticket.job), "admission stays held until cancellation cleanup exits")
        #expect(await runner.read(ticket.job, offset: 0)?.summary.done == false)
        runningGate.release()
        await runningStop.value
        #expect(await runner.activity == .idle)
        #expect(await runner.cancelAllWaiterCount == 0)
        #expect(await runner.read(ticket.job, offset: 0)?.summary.cancelled == true)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
        let gate = TestStepGate()
        defer { gate.release() }
        let committing = env.runner(beforePublish: { await gate.wait() })
        let committed = try await committing.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { gate.entered })
        #expect(await committing.activity == .committing(committed.job))
        let returned = Mutex(false)
        let stop = Task { await committing.cancelAll(); returned.withLock { $0 = true } }
        try #require(await eventually(timeout: .seconds(10)) { await committing.cancelAllWaiterCount == 1 })
        #expect(!returned.withLock { $0 })
        #expect(!gate.cancelled, "commit is awaited rather than cancelled")
        #expect(await committing.activity == .committing(committed.job))
        gate.release()
        await stop.value
        #expect(await committing.activity == .idle)
        #expect(await committing.cancelAllWaiterCount == 0)
        #expect(await committing.read(committed.job, offset: 0)?.summary.failure == nil)
        #expect(await env.sessions.exports(for: photo.id).count == 1)
    }

    @Test func resolvedKeysIgnoreDisplayMetadataAndTemporaryPaths() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), runner = env.runner()
        let base = try await runner.exportKey(session: photo.id, options: EditOptions())
        let defaults: [String: JSONValue] = ["brightness": .number(0.6)]
        let explicit = try await runner.exportKey(session: photo.id, options: EditOptions(defaults))
        #expect(explicit == base)
        #expect(try await runner.exportKey(session: photo.id, options: EditOptions(["lutName": .string("Label")])) == base)
        #expect(try await runner.exportKey(session: photo.id, options: EditOptions(["brightness": .number(0.5)])) != base)
        var request = try Engine.normalize([:])
        let originalKey = try ExportKey(request: request, frame: nil)
        try request.setCommand("input", .string("other.png"))
        try request.setCommand("output", .string("/temporary/export"))
        try request.setCommand("report", .string("/temporary/report"))
        #expect(try ExportKey(request: request, frame: nil) == originalKey)
        request.setSetting("quality", .number(42))
        #expect(try ExportKey(request: request, frame: nil) != originalKey)
        let frame = ExportFrame(spec: ["schema": .string("hyperdr.frame/v1")])
        #expect(try await runner.exportKey(session: photo.id, options: EditOptions(), frame: frame) != base)
        let a = try ExportFrameRecord(ExportFrame(spec: frame.spec, overlayPNG: Data([1])))
        let b = try ExportFrameRecord(ExportFrame(spec: frame.spec, overlayPNG: Data([2])))
        #expect(a.overlaySHA256 != b.overlaySHA256)
        #expect(a.spec["overlay"] == nil)
        let placeholder = try await runner.commandLine(session: photo.id, options: EditOptions(), frame: frame)
        #expect(placeholder.first == "HyperDR")
        #expect(placeholder.contains("<导出文件夹>"))
        #expect(placeholder.contains("<导出文件夹>/report.json"))
        #expect(placeholder.contains("<导出文件夹>/frame.json"))
        let ticket = try await runner.start(session: photo.id, options: EditOptions(), frame: frame)
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let record = try #require(await env.sessions.exports(for: photo.id).first)
        #expect(record.key == (try await runner.exportKey(session: photo.id, options: EditOptions(), frame: frame)))
        #expect(record.frame == (try ExportFrameRecord(frame)))
        #expect(!ticket.argv.contains("<导出文件夹>"))
        let result = try await env.sessions.resultURL(photo.id, export: ticket.export)
        let manifest = result.deletingLastPathComponent().appendingPathComponent("result.json")
        let original = try Data(contentsOf: manifest)
        let first = SavedMark(fileName: "first.tif", folderLabel: "…/Photos")
        try await env.sessions.markSaved(photo.id, export: ticket.export, saved: first)
        #expect(await env.sessions.exports(for: photo.id).first?.saved?.fileName == first.fileName)
        let last = SavedMark(fileName: "last.tif", folderLabel: "…/Exports")
        try await env.sessions.markSaved(photo.id, export: ticket.export, saved: last)
        #expect(await env.sessions.exports(for: photo.id).first?.saved?.fileName == last.fileName)
        #expect(await env.sessions.exports(for: photo.id).first?.saved?.folderLabel == last.folderLabel)
        let savedAt = try #require(await env.sessions.exports(for: photo.id).first?.saved?.savedAt)
        #expect(abs(savedAt.timeIntervalSince(last.savedAt)) < 0.001)
        #expect(try Data(contentsOf: manifest) == original)
        var old = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        old.removeValue(forKey: "key")
        try JSONSerialization.data(withJSONObject: old).write(to: manifest)
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
    }
}

@Suite(.timeLimit(.minutes(1))) struct M3HistoryTests {
    private func publish(_ env: JobEnvironment, _ photo: PhotoSession) async throws -> ExportRecord {
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        return try #require(await runner.read(ticket.job, offset: 0)?.summary.result)
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
        try await env.sessions.markSaved(a.id, export: first.id, saved: SavedMark(fileName: "trimmed.tif", folderLabel: "…/out"))
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
        try await env.sessions.markSaved(photo.id, export: first.id, saved: SavedMark(fileName: result.name, folderLabel: result.folderLabel))
        #expect(await env.sessions.exports(for: photo.id).count == 1)
    }
}

@Suite(.timeLimit(.minutes(1))) struct M3SavePanelTests {
    @Test func exactFilenameReplacesAtomicallyButFolderSavesStillAvoidCollisions() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let folder = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        let exact = folder.appendingPathComponent("my export.tif")
        try Data([9]).write(to: exact)
        // A reader holding the original inode sees all old bytes after replace.
        let old = try FileHandle(forReadingFrom: exact)
        defer { try? old.close() }
        let saved = try await target.save(session: photo.id, export: ticket.export, to: exact)
        #expect(saved.name == exact.lastPathComponent)
        #expect(try Data(contentsOf: exact) == Data([1,2,3]))
        #expect(try old.readToEnd() == Data([9]))
        #expect(await target.folder.ready == false)
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export,
            to: folder.appendingPathComponent("wrong.jpg")) } == "invalid_options")
        #expect(await failureCode { _ = try await target.save(session: photo.id, export: ticket.export,
            to: env.configuration.supportDirectory.appendingPathComponent("forbidden.tif")) } == "export_folder_inside_workspace")
        let first = try await target.save(session: photo.id, export: ticket.export, oneOff: folder)
        let second = try await target.save(session: photo.id, export: ticket.export, oneOff: folder)
        #expect(first.name == "photo.tif")
        #expect(second.name == "photo (2).tif")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasPrefix(".hyperdr-export-") })
    }

    @Test func failedOrCancelledCopyKeepsExistingDestinationAndCleansStaging() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        try #require(await eventually(timeout: .seconds(10)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        let folder = env.root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let exact = folder.appendingPathComponent("keep.tif")
        try Data([9]).write(to: exact)
        let fail = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { _, _, _ in errno = EIO; return -1 })
        #expect(await failureCode { _ = try await fail.save(session: photo.id, export: ticket.export, to: exact) } == "export_folder_unwritable")
        let reached = Mutex(false), gate = BlockingJobGate()
        let cancelling = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { fd, buffer, count in
                reached.withLock { $0 = true }
                gate.waitForRelease()
                return Darwin.read(fd, buffer, count)
            })
        let save = Task { try await cancelling.save(session: photo.id, export: ticket.export, to: exact) }
        defer { gate.release() }
        try #require(await eventually(timeout: .seconds(10)) { reached.withLock { $0 } })
        save.cancel(); gate.release()
        do { _ = try await save.value; Issue.record("Expected cancellation") } catch is CancellationError {}
        #expect(!gate.didTimeOut)
        #expect(try Data(contentsOf: exact) == Data([9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.tif"])
    }
}

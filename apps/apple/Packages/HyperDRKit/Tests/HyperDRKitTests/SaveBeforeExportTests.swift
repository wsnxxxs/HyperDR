import CoreGraphics
import ImageIO
import Darwin
import Foundation
import HyperDREngine
import Synchronization
import Testing
@testable import HyperDRKit

private actor SaveGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class SaveAccess: SecurityScopedAccess {
    let active = Mutex(0)
    func startAccessing(_ url: URL) -> Bool { active.withLock { $0 += 1 }; return true }
    func stopAccessing(_ url: URL) { active.withLock { $0 -= 1 } }
}

private func eventually(timeout: Duration, _ check: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await check() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await check()
}

@Suite(.timeLimit(.minutes(1))) struct SaveBeforeExportTests {
    private func destination(_ env: JobEnvironment) throws -> URL {
        let folder = env.root.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("chosen name.tif")
        try Data([9]).write(to: file)
        return file
    }
    private func finish(_ runner: JobRunner, _ ticket: JobTicket) async throws -> JobSummary {
        try #require(await eventually(timeout: .seconds(3)) { await runner.read(ticket.job, offset: 0)?.summary.done == true })
        return try #require(await runner.read(ticket.job, offset: 0)?.summary)
    }

    @Test func chosenURLIsHeldBeforeConversionAndSuccessArrivesAfterDelivery() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let access = SaveAccess(), gate = SaveGate()
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions, access: access)
        let runner = env.runner(convert: { request, _ in
            await gate.wait()
            let output = URL(fileURLWithPath: request.command["output"]!.stringValue!).appendingPathComponent("photo.tif")
            try Data([1,2,3]).write(to: output)
            return ConvertReport(json: Data("{}".utf8), files: [ReportFile(input: "", output: output.path,
                success: true, skipped: false, message: "", width: 800, height: 600)])
        }, exportTarget: target)
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]), destination: url)
        try #require(await eventually(timeout: .seconds(2)) { await gate.entered })
        #expect(access.active.withLock { $0 } == 1)
        #expect(try Data(contentsOf: url) == Data([9]))
        #expect(await runner.read(ticket.job, offset: 0)?.summary.done == false)
        let events = runner.events(ticket.job)
        await gate.release()
        var stages: [String] = []
        for await event in events {
            switch event {
            case .publishing: stages.append("publishing")
            case .saving: stages.append("saving")
            case .finished: stages.append("finished")
            default: break
            }
        }
        #expect(stages == ["publishing", "saving", "finished"])
        let summary = try await finish(runner, ticket)
        #expect(summary.failure == nil)
        #expect(summary.saved?.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
        #expect(summary.saved?.name == "chosen name.tif")
        #expect(summary.result?.saved?.fileName == "chosen name.tif")
        #expect(await env.sessions.exports(for: photo.id).first?.saved?.fileName == "chosen name.tif")
        #expect(try Data(contentsOf: url) == Data([1,2,3]))
        #expect(access.active.withLock { $0 } == 0)
        #expect(await runner.activity == .idle)
    }

    @Test func conversionFailureLeavesChosenFileUntouched() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let runner = env.runner(convert: { _, _ in ConvertReport(json: Data("{}".utf8), files: []) })
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]), destination: url)
        let result = try await finish(runner, ticket)
        #expect(result.failure?.code == "export_failed")
        #expect(result.saved == nil && result.result == nil)
        #expect(try Data(contentsOf: url) == Data([9]))
        #expect(await env.sessions.exports(for: photo.id).isEmpty)
    }

    @Test func failedDeliveryRetainsExportForRetryWithoutReplacingUserFile() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { _, _, _ in errno = EIO; return -1 })
        let runner = env.runner(exportTarget: target)
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]), destination: url)
        let result = try await finish(runner, ticket)
        #expect(result.failure?.code == "export_folder_unwritable")
        #expect(result.result?.id == ticket.export)
        #expect(result.saved == nil && result.result?.saved == nil)
        #expect(await env.sessions.exports(for: photo.id).count == 1)
        #expect(try Data(contentsOf: url) == Data([9]))
    }

    @Test func cancelAllStopsDeliveryButPreservesPublishedHistory() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let reached = Mutex(false)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), copyRead: { fd, buffer, count in
                reached.withLock { $0 = true }
                let deadline = ContinuousClock.now + .seconds(3)
                // Stand in for a slow read on the detached copier; only this
                // background test seam blocks, never the actor/test executor.
                while !Task.isCancelled && ContinuousClock.now < deadline { usleep(1000) }
                return Darwin.read(fd,buffer,count)
            })
        let runner = env.runner(exportTarget: target)
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]), destination: url)
        try #require(await eventually(timeout: .seconds(2)) { reached.withLock { $0 } })
        await runner.cancelAll()
        let result = try await finish(runner, ticket)
        #expect(result.failure?.code == "cancelled")
        #expect(!result.cancelled) // Publication itself is never rolled back.
        #expect(result.result?.id == ticket.export)
        #expect(await env.sessions.exports(for: photo.id).count == 1)
        #expect(try Data(contentsOf: url) == Data([9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [url.lastPathComponent])
    }

    @Test func workspaceDestinationIsRejectedBeforeConversion() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), called = Mutex(false)
        let runner = env.runner(convert: { _, _ in
            called.withLock { $0 = true }; return ConvertReport(json: Data("{}".utf8), files: [])
        })
        do {
            _ = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]),
                destination: env.configuration.supportDirectory.appendingPathComponent("forbidden.tif"))
            Issue.record("Expected workspace rejection")
        } catch let error as HyperDRError { #expect(error.code == "export_folder_inside_workspace") }
        #expect(!called.withLock { $0 })
        #expect(await runner.activity == .idle)
    }
}

extension SaveBeforeExportTests {
    @Test func suggestedNamesMatchEveryLocallyAvailableEngineEncoding() async throws {
        let env = try JobEnvironment()
        let source = env.root.appendingPathComponent("small.input.png")
        let context = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let output = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(output))
        let kit = try await HyperDRKit(configuration: env.configuration)
        let photo = try await kit.sessions.open(source)
        var checked = 0
        for encoding in kit.capabilities.encodings where encoding.available {
            let options = EditOptions(["encoding": .string(encoding.id)])
            let suggested = try await kit.jobs.suggestedFileName(session: photo.id, options: options)
            let ticket = try await kit.jobs.start(session: photo.id, options: options)
            let summary = try await finish(kit.jobs, ticket)
            #expect(summary.failure == nil, "encoding=\(encoding.id)")
            let record = try #require(summary.result)
            #expect(record.name == suggested, "encoding=\(encoding.id)")
            #expect(suggested.hasPrefix("small.input-hyperdr."))
            checked += 1
        }
        #expect(checked >= 2)
        print("M3 suggested filenames: \(checked) available encodings checked")
    }

    @Test func destinationValidationChecksExtensionAndDoesNotTouchSelectedFile() async throws {
        let env = try JobEnvironment(), url = try destination(env)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        try await target.validateDestination(url, expectedExtension: "tif")
        do { try await target.validateDestination(url, expectedExtension: "jpg"); Issue.record("Expected extension rejection") }
        catch let error as HyperDRError { #expect(error.code == "invalid_options") }
        let missing = env.root.appendingPathComponent("missing/file.tif")
        do { try await target.validateDestination(missing, expectedExtension: "tif"); Issue.record("Expected missing directory rejection") }
        catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(try Data(contentsOf: url) == Data([9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == [url.lastPathComponent])
    }

    @Test func replacementDirectoryFallbackNeverTruncatesAnOldFileAndCleansNewFailures() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), runner = env.runner(), old = try destination(env)
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        _ = try await finish(runner, ticket)
        var hooks = ExportTarget.CopyHooks()
        hooks.replacementDirectory = { _ in throw CocoaError(.fileWriteNoPermission) }
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do { _ = try await target.save(session: photo.id, export: ticket.export, to: old); Issue.record("Expected safe replacement rejection") }
        catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(try Data(contentsOf: old) == Data([9]))
        let fresh = old.deletingLastPathComponent().appendingPathComponent("new.tif")
        try await target.validateDestination(fresh, expectedExtension: "tif")
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        let saved = try await target.save(session: photo.id, export: ticket.export, to: fresh)
        #expect(try Data(contentsOf: saved.url) == Data([1,2,3]))
        hooks.read = { _, _, _ in errno = EIO; return -1 }
        let failing = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        let partial = old.deletingLastPathComponent().appendingPathComponent("partial.tif")
        do { _ = try await failing.save(session: photo.id, export: ticket.export, to: partial); Issue.record("Expected I/O failure") }
        catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        let swapped = old.deletingLastPathComponent().appendingPathComponent("swapped.tif")
        let once = Mutex(false)
        hooks.read = { fd, buffer, count in
            let swap = once.withLock { value in if value { return false }; value = true; return true }
            if swap {
                do {
                    try FileManager.default.moveItem(at: swapped, to: swapped.appendingPathExtension("ours"))
                    try Data([7]).write(to: swapped)
                } catch { Issue.record("Unable to arrange fallback destination race: \(error)") }
            }
            return Darwin.read(fd, buffer, count)
        }
        let racing = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do { _ = try await racing.save(session: photo.id, export: ticket.export, to: swapped); Issue.record("Expected replacement race rejection") }
        catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(try Data(contentsOf: swapped) == Data([7]))
    }
}



extension SaveBeforeExportTests {
    @Test func reviewerParentRetargetCannotOverwriteWorkspace() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions())
        _ = try await finish(runner, ticket)
        let forbidden = env.configuration.supportDirectory.appendingPathComponent(url.lastPathComponent)
        try Data([7]).write(to: forbidden)
        let once = Mutex(false)
        var hooks = ExportTarget.CopyHooks()
        hooks.read = { fd, buffer, count in
            if once.withLock({ value in if value { return false }; value = true; return true }) {
                let folder = url.deletingLastPathComponent()
                do {
                    try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("original"))
                    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: env.configuration.supportDirectory)
                } catch { Issue.record("Cannot arrange parent replacement: \(error)") }
            }
            return Darwin.read(fd, buffer, count)
        }
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do { _ = try await target.save(session: photo.id, export: ticket.export, to: url) }
        catch { print("REVIEW parent swap rejected: \(error)") }
        let observed = try Data(contentsOf: forbidden)
        print("REVIEW workspace bytes after parent retarget: \(Array(observed))")
        #expect(observed == Data([7]), "Must not overwrite an excluded workspace through a replaced destination ancestor")
    }
}


extension SaveBeforeExportTests {
    @Test func parentRetargetAtPublicationIsRejectedWithoutChangingEitherOldFile() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let runner = env.runner(), ticket = try await runner.start(session: photo.id, options: EditOptions())
        _ = try await finish(runner, ticket)
        let forbidden = env.configuration.cacheDirectory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: env.configuration.cacheDirectory, withIntermediateDirectories: true)
        try Data([7]).write(to: forbidden)
        var hooks = ExportTarget.CopyHooks()
        hooks.beforeSelectedPublish = {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("original"))
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: env.configuration.cacheDirectory)
        }
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do {
            _ = try await target.save(session: photo.id, export: ticket.export, to: url)
            Issue.record("Expected changed parent rejection")
        } catch let error as HyperDRError { #expect(error.code == "export_folder_inside_workspace") }
        #expect(try Data(contentsOf: forbidden) == Data([7]))
        let original = url.deletingLastPathComponent().appendingPathExtension("original").appendingPathComponent(url.lastPathComponent)
        #expect(try Data(contentsOf: original) == Data([9]))
    }

    @Test func publicationResultMustStillBelongToTheSelectedDirectory() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), url = try destination(env)
        let runner = env.runner(), ticket = try await runner.start(session: photo.id, options: EditOptions())
        _ = try await finish(runner, ticket)
        var hooks = ExportTarget.CopyHooks()
        hooks.afterSelectedPublish = {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.moveItem(at: folder, to: folder.appendingPathExtension("original"))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([7]).write(to: url)
        }
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions,
            access: SystemSecurityScopedAccess(), hooks: hooks)
        do {
            _ = try await target.save(session: photo.id, export: ticket.export, to: url)
            Issue.record("Must not report a replacement directory as saved")
        } catch let error as HyperDRError { #expect(error.code == "export_folder_unwritable") }
        #expect(try Data(contentsOf: url) == Data([7]))
        let actual = url.deletingLastPathComponent().appendingPathExtension("original").appendingPathComponent(url.lastPathComponent)
        #expect(try Data(contentsOf: actual) == Data([1,2,3]))
    }

    @Test func newSelectedFileAndWorkspaceSymlinkValidation() async throws {
        let env = try JobEnvironment(), photo = try await env.photo(), old = try destination(env)
        let url = old.deletingLastPathComponent().appendingPathComponent("new.tif")
        let runner = env.runner()
        let ticket = try await runner.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]), destination: url)
        let summary = try await finish(runner, ticket)
        #expect(summary.failure == nil)
        #expect(try Data(contentsOf: url) == Data([1,2,3]))
        #expect(summary.saved?.syncConfirmed == false, "File-level grants cannot sync the parent directory")
        let alias = env.root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: env.configuration.supportDirectory)
        let target = ExportTarget(configuration: env.configuration, sessions: env.sessions)
        do {
            try await target.validateDestination(alias.appendingPathComponent("invalid.tif"), expectedExtension: "tif")
            Issue.record("Expected workspace identity rejection")
        } catch let error as HyperDRError { #expect(error.code == "export_folder_inside_workspace") }
    }
}

// Standalone signed App Sandbox integration host. See scripts/test_export_folder_sandbox.py.
// Sandbox SPI is test-only; product code never issues or consumes extensions.
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import HyperDRKit
import HyperDREngine
import ImageIO
import UniformTypeIdentifiers

private struct CheckFailure: Error { let message: String }
private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure(message: message) }
    print("PASS \(message)")
}

@main struct ExportFolderSandboxHost {
    static func main() async {
        do { try await run() }
        catch { print("FAIL \(error)"); exit(1) }
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 5,
              let library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW),
              let symbol = dlsym(library, "sandbox_extension_consume") else {
            throw CheckFailure(message: "Expected two directory grants")
        }
        let consume = unsafeBitCast(symbol, to: (@convention(c) (UnsafePointer<CChar>) -> Int64).self)
        for index in [1, 3] {
            try check(CommandLine.arguments[index].withCString { consume($0) } >= 0, "consume selected directory grant")
        }
        let alpha = URL(fileURLWithPath: CommandLine.arguments[2]), beta = URL(fileURLWithPath: CommandLine.arguments[4])
        errno = 0
        let parent = open(alpha.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        let denied = errno
        if parent >= 0 { close(parent) }
        try check(parent < 0 && denied == EPERM, "unselected parent remains unreadable")
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("export-folder-sandbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: workspace.appendingPathComponent("support"), cacheDirectory: workspace.appendingPathComponent("cache")))
        do {
            _ = try await kit.exportTarget.setFolder(workspace.appendingPathComponent("support"))
            throw CheckFailure(message: "Workspace unexpectedly accepted")
        } catch let error as HyperDRError {
            try check(error.code == "export_folder_inside_workspace", "workspace identity exclusion in sandbox")
        }
        let source = workspace.appendingPathComponent("input.jpg")
        try makeJPEG(source)
        let photo = try await kit.sessions.open(source)
        _ = try await kit.exportTarget.setFolder(alpha)
        let first = try await kit.exportTarget.captureFolder()
        let ticket = try await kit.jobs.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff")]))
        try await finish(kit, ticket.job)
        let original = try await kit.sessions.resultURL(photo.id, export: ticket.export)
        let expected = try Data(contentsOf: original)
        let saved = try await kit.exportTarget.save(session: photo.id, export: ticket.export, folder: first)
        try check(saved.url.deletingLastPathComponent().standardizedFileURL.path == alpha.standardizedFileURL.path,
                  "setFolder then save uses alpha")
        try check(try Data(contentsOf: saved.url) == expected, "saved bytes match export")

        // Capture exactly as the model does, before starting the job. Preference
        // mutation happens while the job exists, before awaiting its completion.
        let captured = try await kit.exportTarget.captureFolder()
        let second = try await kit.jobs.start(session: photo.id, options: EditOptions(["encoding": .string("sdr-tiff"), "brightness": .number(0.2)]))
        _ = try await kit.exportTarget.setFolder(beta)
        try await finish(kit, second.job)
        let stillAlpha = try await kit.exportTarget.save(session: photo.id, export: second.export, folder: captured)
        try check(stillAlpha.url.deletingLastPathComponent().standardizedFileURL.path == alpha.standardizedFileURL.path,
                  "preference change during export keeps captured alpha")
        try check(try FileManager.default.contentsOfDirectory(atPath: beta.path).isEmpty, "beta has no redirected copy")
        print("READY_FOR_PARENT_RENAME"); fflush(stdout)
        // The launcher performs an adversarial parent rename, which requires
        // rights intentionally absent from this sandbox. This is a pipe gate.
        guard readLine() == "RENAMED" else { throw CheckFailure(message: "Missing rename gate") }
        let renamedSave = try await kit.exportTarget.save(session: photo.id, export: second.export, folder: captured)
        try check(renamedSave.url.deletingLastPathComponent().lastPathComponent == "alpha-moved",
                  "renamed alpha FD stays pinned despite old-path symlink")
        let secondSource = try await kit.sessions.resultURL(photo.id, export: second.export)
        // The renewed grant ends with Kit's save; verify the resulting bytes
        // in the unsandboxed launcher, without granting this app a new folder.
        let digest = SHA256.hash(data: try Data(contentsOf: secondSource)).map { String(format: "%02x", $0) }.joined()
        let verification = ["name": renamedSave.name, "sha256": digest]
        let json = try JSONSerialization.data(withJSONObject: verification, options: [.sortedKeys])
        print("VERIFY_RENAMED_EXPORT " + String(decoding: json, as: UTF8.self))
        try check(try FileManager.default.contentsOfDirectory(atPath: beta.path).isEmpty, "symlink target beta remains untouched")
        let next = try await kit.exportTarget.captureFolder()
        let nextSaved = try await kit.exportTarget.save(session: photo.id, export: ticket.export, folder: next)
        try check(nextSaved.url.deletingLastPathComponent().standardizedFileURL.path == beta.standardizedFileURL.path,
                  "next snapshot uses beta")
        await kit.sessions.close(photo.id)
        print("EXPORT_FOLDER_SANDBOX_PASSED")
    }

    static func finish(_ kit: HyperDRKit, _ job: JobID) async throws {
        for await event in kit.jobs.events(job) {
            if case .finished(let result) = event {
                if let failure = result.failure { throw failure }
                guard result.result != nil else { throw CheckFailure(message: "Missing export result") }
                return
            }
        }
        throw CheckFailure(message: "Missing terminal export event")
    }

    static func makeJPEG(_ url: URL) throws {
        let pixels = [UInt8](repeating: 127, count: 32 * 24 * 4)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 32, height: 24, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CheckFailure(message: "Unable to create synthetic JPEG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        try check(CGImageDestinationFinalize(destination), "create synthetic source inside sandbox")
    }
}

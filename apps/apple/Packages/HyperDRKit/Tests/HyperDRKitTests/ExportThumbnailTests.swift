import CoreGraphics
import Darwin
import Foundation
import HyperDREngine
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDRKit

private func thumbnailImage(_ width: Int = 16, _ height: Int = 8) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.4, 0.6, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}
private func thumbnailJPEG(_ image: CGImage) throws -> Data {
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return bytes as Data
}
private func publishThumbnail(_ env: JobEnvironment, _ photo: PhotoSession, thumbnail: ExportThumbnail?) async throws -> (ExportID, URL) {
    let version = try await env.sessions.prepareExport(photo.id, options: [:], key: ExportKey(rawValue: "fixture"), thumbnail: thumbnail)
    // Permission-failure tests restore the directory only after preparation
    // returned successfully; the thumbnail write itself ran under mode 0555.
    try #require(chmod(version.directory.path, 0o755) == 0)
    let file = version.directory.appendingPathComponent("photo.jpg")
    try Data([1, 2, 3]).write(to: file)
    let report = ExportPublication(json: Data("{}".utf8), files: [ExportOutput(input: "", output: file.path,
        success: true, skipped: false, message: "", width: 16, height: 8)])
    _ = try await env.sessions.publishExport(photo.id, export: version.id, report: report)
    return (version.id, version.directory)
}

@Suite(.timeLimit(.minutes(1))) struct ExportThumbnailTests {
    @Test func jpegValidationAndDisplayP3Profile() throws {
        let thumbnail = try ExportThumbnail(image: thumbnailImage())
        #expect(try ExportThumbnail(jpegData: thumbnail.jpegData) == thumbnail)
        #expect(thumbnail.jpegData.range(of: Data("ICC_PROFILE\0".utf8)) != nil)
        let source = try #require(CGImageSourceCreateWithData(thumbnail.jpegData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        for data in [Data([1, 2, 3]), try thumbnailJPEG(thumbnailImage(257, 2)),
                     Data(repeating: 0, count: ExportThumbnail.maxByteCount + 1)] {
            #expect(throws: HyperDRError.self) { try ExportThumbnail(jpegData: data) }
        }
        #expect(throws: HyperDRError.self) { try ExportThumbnail(image: thumbnailImage(257, 2)) }
    }

    @Test func versionLifecycleAndUntrustedReads() async throws {
        let env = try JobEnvironment(historyLimit: 1), photo = try await env.photo()
        let thumbnail = try ExportThumbnail(image: thumbnailImage())
        let (first, directory) = try await publishThumbnail(env, photo, thumbnail: thumbnail)
        let path = directory.appendingPathComponent("thumbnail.jpeg")
        #expect(try Data(contentsOf: path) == thumbnail.jpegData)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == thumbnail.jpegData)
        try FileManager.default.removeItem(at: path)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        let outside = env.root.appendingPathComponent("outside.jpeg")
        try thumbnail.jpegData.write(to: outside)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        try FileManager.default.removeItem(at: path)
        try Data(repeating: 1, count: ExportThumbnail.maxByteCount + 1).write(to: path)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        try FileManager.default.removeItem(at: path)
        try #require(mkfifo(path.path, 0o600) == 0)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        try FileManager.default.removeItem(at: path)
        try thumbnail.jpegData.write(to: path)
        let moved = directory.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == thumbnail.jpegData)
        let (_, secondDirectory) = try await publishThumbnail(env, photo, thumbnail: nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(await env.sessions.exportThumbnail(photo.id, export: first) == nil)
        let pending = try await env.sessions.prepareExport(photo.id, options: [:], key: ExportKey(rawValue: "fixture"), thumbnail: thumbnail)
        try await env.sessions.discardExport(photo.id, export: pending.id)
        #expect(!FileManager.default.fileExists(atPath: pending.directory.path))
        #expect(FileManager.default.fileExists(atPath: secondDirectory.path))
        #expect(await env.sessions.exportThumbnail(photo.id, export: ExportID(rawValue: "../outside")) == nil)
    }

    @Test func retainedThumbnailDoesNotNeedTheSourceOrASecurityScope() async throws {
        let env = try JobEnvironment(), photo = try await env.photo()
        let thumbnail = try ExportThumbnail(image: thumbnailImage())
        let (id, _) = try await publishThumbnail(env, photo, thumbnail: thumbnail)
        await env.sessions.close(photo.id)
        try FileManager.default.removeItem(at: photo.sourceURL)
        #expect(await env.sessions.exportThumbnail(photo.id, export: id) == thumbnail.jpegData)
    }

    @Test func readOnlyThumbnailWriteDoesNotFailPublication() async throws {
        let env = try JobEnvironment(beforeThumbnailWrite: { fd in #expect(fchmod(fd, 0o555) == 0) })
        let photo = try await env.photo(), thumbnail = try ExportThumbnail(image: thumbnailImage())
        let (id, directory) = try await publishThumbnail(env, photo, thumbnail: thumbnail)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("thumbnail.jpeg").path))
        #expect(await env.sessions.exports(for: photo.id).contains { $0.id == id })
        #expect(await env.sessions.exportThumbnail(photo.id, export: id) == nil)
    }

}

/// The generated test photo leaves nothing behind (R6-TINY-1).
@Suite struct TinyPhotoCleanupTests {
    @Test func aPhotoIsPrivateAndItsDirectoryGoesWithIt() throws {
        // Not a count of the temporary folder: other tests make photos at the same time.
        let first = try TinyPhoto(), second = try TinyPhoto()
        #expect(first.url.deletingLastPathComponent() != second.url.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        first.remove(); first.remove(); second.remove()
        #expect(!FileManager.default.fileExists(atPath: first.url.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: second.url.deletingLastPathComponent().path))
    }
}

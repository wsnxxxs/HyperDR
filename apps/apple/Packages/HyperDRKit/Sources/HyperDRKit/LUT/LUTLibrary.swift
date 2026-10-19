import Darwin
import Foundation
import HyperDREngine

public actor LUTLibrary {
    private let root: URL
    private let sessions: SessionStore
    private let access: any SecurityScopedAccess

    public init(configuration: KitConfiguration, sessions: SessionStore) {
        root = configuration.supportDirectory.appendingPathComponent("lut-library")
        self.sessions = sessions; access = SystemSecurityScopedAccess()
    }
    public func entries() -> [LUTEntry] {
        guard let directory = try? LUTFiles.directory(root) else { return [] }
        defer { Darwin.close(directory) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> LUTEntry? in
            guard name.hasSuffix(".json"), let id = try? LUTID(rawValue: String(name.dropLast(5))),
                  var entry = try? LUTFiles.metadata(name, in: directory), entry.id == id,
                  let blob = try? LUTFiles.file(id.rawValue + ".cube", in: directory) else { return nil }
            var info = stat()
            guard fstat(blob, &info) == 0 else { Darwin.close(blob); return nil }
            entry.byteCount = UInt64(max(0, info.st_size))
            Darwin.close(blob)
            return entry
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    public func importLUT(_ url: URL, into session: SessionID? = nil) async throws -> LUTEntry {
        guard url.isFileURL, url.pathExtension.lowercased() == "cube" else { throw LUTFiles.invalid("Select a .cube LUT") }
        let lease = SecurityScopeLease(url: url, access: access)
        defer { lease.stop() }
        let source = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard source >= 0 else { throw LUTFiles.invalid("Unable to open LUT") }
        defer { Darwin.close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw LUTFiles.invalid() }
        let directory = try LUTFiles.directory(root, create: true)
        defer { Darwin.close(directory) }
        let id = try LUTFiles.install(source, in: directory)
        let metadataName = id.rawValue + ".json"
        let entry: LUTEntry
        var existing = stat()
        if fstatat(directory, metadataName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            entry = try LUTFiles.metadata(metadataName, in: directory)
            guard entry.id == id else { throw LUTFiles.invalid() }
        } else {
            entry = LUTEntry(id: id, name: String(url.lastPathComponent.unicodeScalars.prefix(160)), input: .srgb, output: .srgb)
            try LUTFiles.writeMetadata(entry, in: directory, replacing: false)
        }
        if let session { return try await apply(entry, from: directory, to: session) }
        return try sized(entry, in: directory)
    }
    public func apply(_ id: LUTID, to session: SessionID) async throws -> LUTEntry {
        let directory = try LUTFiles.directory(root)
        defer { Darwin.close(directory) }
        let entry = try LUTFiles.metadata(id.rawValue + ".json", in: directory)
        guard entry.id == id else { throw LUTFiles.invalid() }
        return try await apply(entry, from: directory, to: session)
    }
    private func apply(_ entry: LUTEntry, from library: Int32, to session: SessionID) async throws -> LUTEntry {
        // Capture both metadata and the immutable source descriptor before the
        // actor suspension. A concurrent removal cannot revoke this apply.
        let source = try LUTFiles.file(entry.id.rawValue + ".cube", in: library)
        defer { Darwin.close(source) }
        var info = stat()
        guard fstat(source, &info) == 0 else { throw LUTFiles.invalid() }
        var result = entry
        result.byteCount = UInt64(max(0, info.st_size))
        let destination = try await sessions.lutDirectory(session)
        _ = try LUTFiles.install(source, in: destination.descriptor, expected: entry.id)
        return result
    }
    public func update(_ id: LUTID, input: LUTSpace, output: LUTSpace) throws -> LUTEntry {
        let directory = try LUTFiles.directory(root)
        defer { Darwin.close(directory) }
        var entry = try LUTFiles.metadata(id.rawValue + ".json", in: directory)
        guard entry.id == id else { throw LUTFiles.invalid() }
        entry.input = input; entry.output = output
        try LUTFiles.writeMetadata(entry, in: directory, replacing: true)
        return try sized(entry, in: directory)
    }
    private func sized(_ entry: LUTEntry, in directory: Int32) throws -> LUTEntry {
        let file = try LUTFiles.file(entry.id.rawValue + ".cube", in: directory)
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0 else { throw LUTFiles.invalid() }
        var result = entry
        result.byteCount = UInt64(max(0, info.st_size))
        return result
    }
    public func remove(_ id: LUTID) throws {
        let directory = try LUTFiles.directory(root)
        defer { Darwin.close(directory) }
        for suffix in [".json", ".cube"] {
            guard unlinkat(directory, id.rawValue + suffix, 0) == 0 || errno == ENOENT else { throw LUTFiles.invalid() }
        }
        guard fsync(directory) == 0 else { throw LUTFiles.invalid("Unable to sync LUT removal") }
    }
}

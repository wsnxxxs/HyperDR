import CryptoKit
import Darwin
import Foundation
import HyperDREngine

/// All resource writes use an exclusively created staging file, fsync, and
/// linkat (new immutable blobs) or renameat (updated metadata), then dir fsync.
enum LUTFiles {
    static let identities = LUTFileIdentityCache()
    static let maximumBytes = 64 * 1024 * 1024
    static func invalid(_ message: String = "The LUT is unavailable; import it again") -> HyperDRError {
        HyperDRError(code: "lut_invalid", message: message)
    }
    static func directory(_ url: URL, create: Bool = false) throws -> Int32 {
        if create {
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            catch { throw invalid("Unable to create LUT directory") }
        }
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid() }
        return fd
    }
    static func directory(_ name: String, in parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw invalid() }
        return fd
    }
    static func file(_ name: String, in parent: Int32) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw invalid() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd); throw invalid()
        }
        return fd
    }
    static func url(_ fd: Int32) throws -> URL {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { throw invalid() }
        return URL(fileURLWithPath: String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw invalid("Unable to write LUT resource") }
                offset += count
            }
        }
    }
    static func metadata(_ name: String, in directory: Int32) throws -> LUTEntry {
        let fd = try file(name, in: directory)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 65537) ?? Data()
        guard !data.isEmpty, data.count <= 65536 else { throw invalid("Invalid LUT metadata") }
        do { return try JSONDecoder().decode(LUTEntry.self, from: data) }
        catch { throw invalid("Invalid LUT metadata") }
    }
    static func writeMetadata(_ entry: LUTEntry, in directory: Int32, replacing: Bool) throws {
        let data = try JSONEncoder().encode(entry)
        let temporary = ".metadata-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("Unable to create LUT metadata") }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try write(data, to: fd)
        guard fsync(fd) == 0 else { throw invalid("Unable to sync LUT metadata") }
        let name = entry.id.rawValue + ".json"
        if replacing {
            guard renameat(directory, temporary, directory, name) == 0 else { throw invalid() }
        } else {
            guard linkat(directory, temporary, directory, name, 0) == 0 else { throw invalid() }
        }
        guard fsync(directory) == 0 else { throw invalid("Unable to sync LUT directory") }
    }

    /// Reads at most max+1 bytes, with incremental SHA-256 and UTF-8/header
    /// validation. Neither the complete file nor an unbounded line is retained.
    static func digest(_ input: Int32, copyingTo output: Int32? = nil) throws -> LUTID {
        let handle = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        var hash = SHA256()
        var parser = CubeHeader()
        var total = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            do { data = try handle.read(upToCount: min(64 * 1024, maximumBytes + 1 - total)) ?? Data() }
            catch { throw invalid("Unable to read LUT") }
            if data.isEmpty { break }
            total += data.count
            guard total <= maximumBytes else {
                throw HyperDRError(code: "lut_too_large", message: "LUT exceeds 64 MB")
            }
            hash.update(data: data)
            try parser.append(data)
            if let output { try write(data, to: output) }
        }
        guard total > 0 else { throw invalid("The LUT is empty") }
        try parser.finish()
        return try LUTID(rawValue: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func install(_ input: Int32, in directory: Int32, expected: LUTID? = nil) throws -> LUTID {
        let temporary = ".import-\(UUID().uuidString)"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw invalid("Unable to stage LUT") }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        let id = try digest(input, copyingTo: fd)
        guard expected == nil || id == expected else { throw invalid("LUT contents do not match their identifier") }
        guard fsync(fd) == 0 else { throw invalid("Unable to sync LUT") }
        let name = id.rawValue + ".cube"
        if linkat(directory, temporary, directory, name, 0) != 0 {
            guard errno == EEXIST else { throw invalid("Unable to publish LUT") }
            let existing = try file(name, in: directory)
            defer { Darwin.close(existing) }
            try identities.verify(existing, in: directory, id: id, useCache: false)
        } else {
            // Record the inode actually hashed/written, never a reopened name.
            // If the directory entry was swapped, resolve will detect it.
            // Unlinking the staging name changes the ctime, so record after it
            // or the first resolve would hash again.
            unlinkat(directory, temporary, 0)
            try identities.rememberInstalled(fd, in: directory, id: id)
        }
        guard fsync(directory) == 0 else { throw invalid("Unable to sync LUT directory") }
        return id
    }
}

private struct CubeHeader {
    private var tail = Data()
    private var first = true
    private var matched = 0
    private var found = false
    private let prefix = Array("LUT_1D_SIZE".unicodeScalars)

    mutating func append(_ bytes: Data) throws {
        var data = tail; data.append(bytes)
        for trim in 0...min(3, data.count) {
            let boundary = data.count - trim
            if let text = String(data: data.prefix(boundary), encoding: .utf8) {
                tail = Data(data.suffix(trim))
                if !found { for scalar in text.unicodeScalars { consume(scalar) } }
                return
            }
        }
        throw LUTFiles.invalid("The LUT is not UTF-8")
    }
    mutating private func consume(_ scalar: Unicode.Scalar) {
        if first { first = false; if scalar.value == 0xfeff { return } }
        if found { return }
        let whitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
        if matched == prefix.count + 1 {
            if (48...57).contains(scalar.value) { found = true; return }
            if whitespace { return }
        }
        if matched == prefix.count {
            if whitespace { matched += 1; return }
        } else if matched >= 0 && matched < prefix.count {
            if matched == 0 && whitespace { return }
            if scalar == prefix[matched] || (matched == 4 && scalar == "3") { matched += 1; return }
        }
        matched = scalar == "\n" ? 0 : -1
    }
    func finish() throws {
        guard tail.isEmpty, found else { throw LUTFiles.invalid("No creative LUT_1D_SIZE or LUT_3D_SIZE header found") }
    }
}

/// The immutable session lookup used by both preview and export. IDs are never
/// paths; every descendant is opened relative to a no-follow directory fd.
struct SessionLUTResolver: Sendable {
    let sessionsDirectory: URL
    init(configuration: KitConfiguration) {
        sessionsDirectory = configuration.supportDirectory.appendingPathComponent("sessions")
    }
    func resolve(_ value: JSONValue?, session: SessionID) throws -> URL? {
        guard value != nil, value != .null, value != .string("") else { return nil }
        guard case .string(let raw) = value, session.isValid else { throw LUTFiles.invalid("Invalid LUT identifier") }
        let id = try LUTID(rawValue: raw)
        let root = try LUTFiles.directory(sessionsDirectory); defer { Darwin.close(root) }
        let photo = try LUTFiles.directory(session.rawValue, in: root); defer { Darwin.close(photo) }
        let directory = try LUTFiles.directory("luts", in: photo); defer { Darwin.close(directory) }
        let file = try LUTFiles.file(id.rawValue + ".cube", in: directory); defer { Darwin.close(file) }
        try LUTFiles.identities.verify(file, in: directory, id: id)
        return try LUTFiles.url(file)
    }
}

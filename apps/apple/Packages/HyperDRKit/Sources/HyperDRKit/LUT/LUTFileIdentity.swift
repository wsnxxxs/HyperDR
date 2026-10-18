import Darwin
import Foundation

/// Trusted, process-local identities of blobs we installed or SHA-verified.
/// A fresh process hashes once; no editable sidecar is trusted as proof of SHA.
/// Bounded storage is shared by the synchronous preview/export resolvers.
final class LUTFileIdentityCache: @unchecked Sendable {
    private struct Key: Hashable {
        let device: dev_t
        let inode: ino_t
        let name: String
    }
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanoseconds: Int
        init(_ file: Int32) throws {
            var info = stat()
            guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size > 0, info.st_size <= LUTFiles.maximumBytes else { throw LUTFiles.invalid() }
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            seconds = info.st_mtimespec.tv_sec; nanoseconds = info.st_mtimespec.tv_nsec
        }
    }
    private let lock = NSLock()
    private var records: [Key: Identity] = [:]

    private func key(_ directory: Int32, id: LUTID) throws -> Key {
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw LUTFiles.invalid() }
        return Key(device: info.st_dev, inode: info.st_ino, name: id.rawValue)
    }
    func rememberInstalled(_ file: Int32, in directory: Int32, id: LUTID) throws {
        let key = try key(directory, id: id), identity = try Identity(file)
        remember(identity, for: key)
    }
    private func remember(_ identity: Identity, for key: Key) {
        lock.withLock {
            if records.count >= 1024, records[key] == nil, let oldest = records.keys.first {
                records.removeValue(forKey: oldest)
            }
            records[key] = identity
        }
    }
    func verify(_ file: Int32, in directory: Int32, id: LUTID, useCache: Bool = true) throws {
        let key = try key(directory, id: id), before = try Identity(file)
        if useCache, lock.withLock({ records[key] == before }) { return }
        guard lseek(file, 0, SEEK_SET) == 0 else { throw LUTFiles.invalid() }
        guard try LUTFiles.digest(file) == id else { throw LUTFiles.invalid("LUT contents do not match their identifier") }
        let after = try Identity(file)
        guard before == after else { throw LUTFiles.invalid("LUT changed during validation") }
        remember(after, for: key)
    }
}

import Darwin
import Foundation
import HyperDREngine

public struct ExportFolderState: Sendable {
    public let label: String
    public let ready: Bool
}
public struct SavedExport: Sendable {
    public let url: URL
    public let name: String
    public let folderLabel: String
}

public actor ExportTarget {
    typealias CopyRead = @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> Int
    private let sessions: SessionStore
    private let roots: [URL]
    private let bookmarkFile: URL
    private let access: any SecurityScopedAccess
    private let copyRead: CopyRead
    private var selected: URL?

    public init(configuration: KitConfiguration, sessions: SessionStore) {
        self.init(configuration: configuration, sessions: sessions, access: SystemSecurityScopedAccess())
    }
    init(configuration: KitConfiguration, sessions: SessionStore, access: any SecurityScopedAccess,
         copyRead: @escaping CopyRead = { Darwin.read($0, $1, $2) }) {
        self.sessions = sessions; self.access = access
        self.copyRead = copyRead
        roots = [configuration.supportDirectory, configuration.cacheDirectory]
        bookmarkFile = configuration.supportDirectory.appendingPathComponent("export-folder.bookmark")
        if let data = try? Data(contentsOf: bookmarkFile) {
            var stale = false
            selected = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
        }
    }
    public var folder: ExportFolderState {
        guard let selected else { return ExportFolderState(label: "", ready: false) }
        let lease = SecurityScopeLease(url: selected, access: access)
        defer { lease.stop() }
        let descriptor = try? Self.openFolder(selected, excluding: roots)
        if let descriptor { Darwin.close(descriptor) }
        return ExportFolderState(label: Self.label(selected), ready: descriptor != nil)
    }

    public func setFolder(_ url: URL) throws -> String {
        let lease = SecurityScopeLease(url: url, access: access)
        defer { lease.stop() }
        let descriptor = try Self.openFolder(url, excluding: roots)
        defer { Darwin.close(descriptor) }
        let probe = ".hyperdr-write-check-\(UUID().uuidString)"
        let file = openat(descriptor, probe, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw Self.error("export_folder_unwritable") }
        Darwin.close(file); unlinkat(descriptor, probe, 0)
        let canonical = try Self.directoryURL(descriptor)
        let scoped: URL
        do {
            let bookmark = try canonical.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            scoped = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            try FileManager.default.createDirectory(at: bookmarkFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bookmark.write(to: bookmarkFile, options: .atomic)
        } catch { throw HyperDRError(code: "export_folder_unwritable", message: "Unable to persist export folder bookmark: \(error)") }
        selected = scoped
        return Self.label(canonical)
    }

    public func save(session: SessionID, export: ExportID, oneOff: URL? = nil) async throws -> SavedExport {
        // Capture the selection before suspension; a preference change during
        // source validation belongs to the next save.
        guard let destination = oneOff ?? selected else { throw Self.error("export_folder_unset") }
        let source = try await sessions.exportFile(session, export: export)
        let roots = self.roots
        let read = copyRead
        let lease = SecurityScopeLease(url: destination, access: access)
        defer { lease.stop() }
        let task = Task.detached {
            try Self.copy(source, to: destination, excluding: roots, read: read)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func label(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.isEmpty ? "…" : "…/" + parts.suffix(2).joined(separator: "/")
    }
    private static func error(_ code: String) -> HyperDRError {
        HyperDRError(code: code, message: code)
    }
    private static func directoryURL(_ descriptor: Int32) throws -> URL {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { throw error("export_folder_unwritable") }
        return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
    }
    /// Resolve symlinks before '..', then compare ancestor file identities.
    /// Keep the resulting descriptor through creation/copy to avoid reopening
    /// an alias that might have been retargeted in the meantime.
    private static func openFolder(_ url: URL, excluding roots: [URL]) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"),
              let real = realpath(url.path, nil) else { throw error("export_folder_unwritable") }
        defer { free(real) }
        let descriptor = Darwin.open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw error("export_folder_unwritable") }
        do {
            let identities: [(dev_t, ino_t)] = roots.compactMap { root in
                var info = stat()
                guard stat(root.path, &info) == 0 else { return nil }
                return (info.st_dev, info.st_ino)
            }
            var ancestor = dup(descriptor)
            guard ancestor >= 0 else { throw error("export_folder_unwritable") }
            defer { Darwin.close(ancestor) }
            while true {
                var current = stat()
                guard fstat(ancestor, &current) == 0 else { throw error("export_folder_unwritable") }
                if identities.contains(where: { $0.0 == current.st_dev && $0.1 == current.st_ino }) {
                    throw error("export_folder_inside_workspace")
                }
                let parent = openat(ancestor, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard parent >= 0 else { throw error("export_folder_unwritable") }
                var info = stat()
                guard fstat(parent, &info) == 0 else { Darwin.close(parent); throw error("export_folder_unwritable") }
                if info.st_dev == current.st_dev && info.st_ino == current.st_ino { Darwin.close(parent); break }
                Darwin.close(ancestor); ancestor = parent
            }
            return descriptor
        } catch { Darwin.close(descriptor); throw error }
    }
    private static func copy(_ source: SessionExportFile, to folder: URL, excluding roots: [URL], read: CopyRead) throws -> SavedExport {
        let directory = try openFolder(folder, excluding: roots)
        defer { Darwin.close(directory) }
        let input = source.descriptor
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw error("source_missing") }
        let temporary = ".hyperdr-export-\(UUID().uuidString)"
        guard mkdirat(directory, temporary, 0o700) == 0 else { throw error("export_folder_unwritable") }
        let staging = openat(directory, temporary, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw error("export_folder_unwritable") }
        var stagingInfo = stat()
        guard fstat(staging, &stagingInfo) == 0, stagingInfo.st_uid == geteuid(),
              stagingInfo.st_mode & 0o777 == 0o700 else {
            Darwin.close(staging)
            throw error("export_folder_unwritable")
        }
        let leaf = "payload"
        defer {
            // Always address our private directory by its held descriptor.
            // If somebody moved/replaced its outer name, leave that other
            // directory alone rather than cleaning a public replacement.
            unlinkat(staging, leaf, 0)
            // A rename within the target directory changes its name, not the
            // held directory. Remove that actual private directory if it is
            // still in our parent; never remove a replacement at the old name.
            if let actual = try? directoryURL(staging), let parent = try? directoryURL(directory),
               actual.deletingLastPathComponent().path == parent.path {
                var current = stat()
                if fstatat(directory, actual.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == stagingInfo.st_dev, current.st_ino == stagingInfo.st_ino,
                   unlinkat(directory, actual.lastPathComponent, AT_REMOVEDIR) == 0 {
                    _ = fsync(directory)
                }
            }
            Darwin.close(staging)
        }
        let output = openat(staging, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw error("export_folder_unwritable") }
        defer { Darwin.close(output) }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = read(input, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw error("export_folder_unwritable") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw error("export_folder_unwritable") }
                    offset += written
                }
            }
        }
        guard fsync(output) == 0 else { throw error("export_folder_unwritable") }
        // F_GETPATH follows the descriptor actually written, including aliases.
        let canonical = try directoryURL(directory)
        let file = URL(fileURLWithPath: source.name)
        let stem = file.deletingPathExtension().lastPathComponent
        let suffix = file.pathExtension.isEmpty ? "" : "." + file.pathExtension
        var number = 1
        var name = source.name
        while true {
            try Task.checkCancellation()
            name = number == 1 ? source.name : "\(stem) (\(number))\(suffix)"
            var opened = stat(), named = stat()
            guard fstat(output, &opened) == 0,
                  fstatat(staging, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_mode & S_IFMT == S_IFREG,
                  opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                throw error("export_folder_unwritable")
            }
            if renameatx_np(staging, leaf, directory, name, UInt32(RENAME_EXCL)) == 0 { break }
            guard errno == EEXIST else { throw error("export_folder_unwritable") }
            number += 1
        }
        guard fsync(directory) == 0 else { throw error("export_folder_unwritable") }
        return SavedExport(url: canonical.appendingPathComponent(name), name: name, folderLabel: label(canonical))
    }
}

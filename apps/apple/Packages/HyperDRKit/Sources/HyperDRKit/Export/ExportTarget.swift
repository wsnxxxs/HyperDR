import Darwin
import Foundation
import HyperDREngine
import os

public struct ExportFolderState: Sendable {
    public let label: String
    public let ready: Bool
}
public struct SavedExport: Sendable {
    public let url: URL
    public let name: String
    public let folderLabel: String
    /// False when the file was published under its name but syncing the
    /// folder failed or file-only authority prevented requesting a directory sync: the export exists and must not be retried as a failure
    /// (that would save a second copy), yet a crash could still lose the name.
    public let syncConfirmed: Bool
}

/// Immutable directory authority retained independently of later preferences.
/// A descriptor pins the selected directory even if its name is replaced.
public final class ExportFolderSnapshot: Sendable {
    public let label: String
    fileprivate let descriptor: Int32
    private let lease: SecurityScopeLease
    fileprivate init(label: String, descriptor: Int32, lease: SecurityScopeLease) {
        self.label = label; self.descriptor = descriptor; self.lease = lease
    }
    deinit { Darwin.close(descriptor) }
}

public actor ExportTarget {
    typealias CopyRead = @Sendable (Int32, UnsafeMutableRawPointer?, Int) -> Int
    /// Test seams for the private staging directory and the final folder sync.
    struct CopyHooks: Sendable {
        var replacementDirectory: @Sendable (URL) throws -> URL = {
            try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                appropriateFor: $0, create: true)
        }
        var read: CopyRead = { Darwin.read($0, $1, $2) }
        var beforeSelectedPublish: @Sendable () throws -> Void = {}
        var afterSelectedPublish: @Sendable () throws -> Void = {}
        var openStaging: @Sendable (Int32, String) -> Int32 = {
            openat($0, $1, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        var syncFolder: @Sendable (Int32) -> Int32 = { fsync($0) }
    }
    private static let log = Logger(subsystem: "com.hyperdr.HyperDR", category: "Export")
    private let sessions: SessionStore
    private let roots: [URL]
    private let bookmarkFile: URL
    private let access: any SecurityScopedAccess
    private let hooks: CopyHooks
    private var selected: URL?

    public init(configuration: KitConfiguration, sessions: SessionStore) {
        self.init(configuration: configuration, sessions: sessions, access: SystemSecurityScopedAccess())
    }
    init(configuration: KitConfiguration, sessions: SessionStore, access: any SecurityScopedAccess,
         copyRead: CopyRead? = nil, hooks: CopyHooks = CopyHooks()) {
        self.sessions = sessions; self.access = access
        var hooks = hooks
        if let copyRead { hooks.read = copyRead }
        self.hooks = hooks
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

    public func captureFolder() throws -> ExportFolderSnapshot {
        guard let selected else { throw Self.error("export_folder_unset") }
        let lease = SecurityScopeLease(url: selected, access: access)
        let descriptor = try Self.openFolder(selected, excluding: roots)
        return ExportFolderSnapshot(label: Self.label(selected), descriptor: descriptor, lease: lease)
    }

    public func save(session: SessionID, export: ExportID, folder: ExportFolderSnapshot) async throws -> SavedExport {
        let source = try await sessions.exportFile(session, export: export)
        let hooks = self.hooks
        let task = Task.detached {
            try withExtendedLifetime(folder) {
                try Self.copy(source, directory: folder.descriptor, hooks: hooks)
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func save(session: SessionID, export: ExportID, oneOff: URL? = nil) async throws -> SavedExport {
        // Capture the selection before suspension; a preference change during
        // source validation belongs to the next save.
        guard let destination = oneOff ?? selected else { throw Self.error("export_folder_unset") }
        let source = try await sessions.exportFile(session, export: export)
        let roots = self.roots
        let hooks = self.hooks
        let lease = SecurityScopeLease(url: destination, access: access)
        defer { lease.stop() }
        let task = Task.detached {
            try Self.copy(source, to: destination, excluding: roots, hooks: hooks)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// The caller supplies the extension from suggestedFileName for its chosen
    /// encoding. No destination file is created or modified during validation.
    public func validateDestination(_ fileURL: URL, expectedExtension: String) throws {
        let lease = try leaseDestination(fileURL, expectedExtension: expectedExtension)
        lease.stop()
    }

    func leaseDestination(_ fileURL: URL, expectedExtension: String) throws -> SecurityScopeLease {
        guard fileURL.isFileURL, !fileURL.hasDirectoryPath, !fileURL.lastPathComponent.isEmpty,
              fileURL.pathExtension.lowercased() == expectedExtension.lowercased() else {
            throw HyperDRError(code: "invalid_options", message: "Invalid save destination or extension")
        }
        let lease = SecurityScopeLease(url: fileURL, access: access)
        let destination = try SelectedDestination(fileURL, excluding: roots)
        if let temporary = try? hooks.replacementDirectory(fileURL) {
            try? FileManager.default.removeItem(at: temporary)
        } else {
            // Never truncate an existing file when atomic replacement is unavailable.
            guard destination.fileIdentity == nil else { throw Self.error("export_folder_unwritable") }
        }
        return lease
    }

    /// The save panel has already confirmed replacement. Keep its exact URL
    /// for security-scoped access and use the system item-replacement directory.
    public func save(session: SessionID, export: ExportID, to fileURL: URL) async throws -> SavedExport {
        let source = try await sessions.exportFile(session, export: export)
        let name = fileURL.lastPathComponent
        guard fileURL.isFileURL, !name.isEmpty, name != ".", name != "..",
              fileURL.pathExtension.lowercased() == URL(fileURLWithPath: source.name).pathExtension.lowercased() else {
            throw HyperDRError(code: "invalid_options", message: "Save destination must use the export's file extension")
        }
        let roots = self.roots, hooks = self.hooks
        let lease = SecurityScopeLease(url: fileURL, access: access)
        defer { lease.stop() }
        let task = Task.detached {
            try Self.copySelected(source, to: fileURL, excluding: roots, hooks: hooks)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    /// Save-panel access grants metadata traversal, not directory enumeration.
    /// This path must never open the selected file's parent or its ancestors.
    private struct SelectedDestination {
        let url: URL
        let directoryIdentity: FileIdentity
        let fileIdentity: FileIdentity?

        init(_ requested: URL, excluding roots: [URL]) throws {
            let parent = requested.deletingLastPathComponent()
            guard let real = realpath(parent.path, nil) else { throw ExportTarget.error("export_folder_unwritable") }
            defer { free(real) }
            var ancestor = URL(fileURLWithPath: String(cString: real), isDirectory: true)
            let canonical = ancestor
            var info = stat()
            guard stat(canonical.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o222 != 0 else { throw ExportTarget.error("export_folder_unwritable") }
            directoryIdentity = FileIdentity(info)
            let excluded = roots.compactMap { root -> FileIdentity? in
                var info = stat()
                return stat(root.path, &info) == 0 ? FileIdentity(info) : nil
            }
            while true {
                guard stat(ancestor.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
                    throw ExportTarget.error("export_folder_unwritable")
                }
                guard !excluded.contains(FileIdentity(info)) else { throw ExportTarget.error("export_folder_inside_workspace") }
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
            url = canonical.appendingPathComponent(requested.lastPathComponent)
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFREG else { throw ExportTarget.error("invalid_options") }
                fileIdentity = FileIdentity(info)
            } else {
                guard errno == ENOENT else { throw ExportTarget.error("export_folder_unwritable") }
                fileIdentity = nil
            }
        }

        func verify(_ requested: URL, excluding roots: [URL], file: FileIdentity?) throws -> URL {
            let current = try SelectedDestination(requested, excluding: roots)
            guard current.directoryIdentity == directoryIdentity, current.url == url,
                  current.fileIdentity == file else { throw ExportTarget.error("export_folder_unwritable") }
            return current.url
        }
    }

    private static func copySelected(_ source: SessionExportFile, to fileURL: URL,
                                     excluding roots: [URL], hooks: CopyHooks) throws -> SavedExport {
        let selected = try SelectedDestination(fileURL, excluding: roots)
        let temporary: URL
        do { temporary = try hooks.replacementDirectory(fileURL) }
        catch {
            return try copyDirectNewFile(source, to: selected.url, directory: nil, hooks: hooks,
                verifyDirectory: {
                    let current = try SelectedDestination(fileURL, excluding: roots)
                    guard current.directoryIdentity == selected.directoryIdentity, current.url == selected.url else {
                        throw ExportTarget.error("export_folder_unwritable")
                    }
                })
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Only the private system-granted replacement directory is opened.
        let temporaryFD = Darwin.open(temporary.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard temporaryFD >= 0 else { throw ExportTarget.error("export_folder_unwritable") }
        defer { Darwin.close(temporaryFD) }
        var temporaryInfo = stat()
        guard fstat(temporaryFD, &temporaryInfo) == 0 else { throw ExportTarget.error("export_folder_unwritable") }
        guard selected.directoryIdentity.device == temporaryInfo.st_dev else {
            return try copyDirectNewFile(source, to: selected.url, directory: nil, hooks: hooks,
                verifyDirectory: {
                    let current = try SelectedDestination(fileURL, excluding: roots)
                    guard current.directoryIdentity == selected.directoryIdentity, current.url == selected.url else {
                        throw ExportTarget.error("export_folder_unwritable")
                    }
                })
        }
        var stagingHooks = hooks
        stagingHooks.syncFolder = { fsync($0) }
        let staged = try copyDirectNewFile(source, to: temporary.appendingPathComponent("payload"),
            directory: temporaryFD, hooks: stagingHooks)
        var stagedInfo = stat()
        guard lstat(staged.url.path, &stagedInfo) == 0 else { throw ExportTarget.error("export_folder_unwritable") }
        let publishedIdentity = FileIdentity(stagedInfo)
        try Task.checkCancellation()
        try hooks.beforeSelectedPublish()
        var coordinationError: NSError?
        var outcome: Result<SavedExport, Error>?
        // Coordination serializes cooperating file presenters. Metadata checks
        // before AND after publication reject persistent parent/target retargets.
        // A hostile same-user process ignoring coordination can still rename an
        // ancestor between the last check and the path-based system call (or
        // perform an ABA swap between checks). File-only authority provides no
        // directory handle for an atomic identity-bound rename; postchecks must
        // not be advertised as preventing every such malicious filesystem race.
        NSFileCoordinator().coordinate(writingItemAt: fileURL, options: .forReplacing, error: &coordinationError) { coordinated in
            outcome = Result {
                try Task.checkCancellation()
                // Re-resolve both the original selection and the coordinator's
                // URL: neither may acquire a different parent or target inode.
                let destination = try selected.verify(fileURL, excluding: roots, file: selected.fileIdentity)
                _ = try selected.verify(coordinated, excluding: roots, file: selected.fileIdentity)
                let result: URL
                if selected.fileIdentity != nil {
                    result = try FileManager.default.replaceItemAt(destination, withItemAt: staged.url,
                        backupItemName: nil, options: .usingNewMetadataOnly) ?? destination
                } else {
                    // Same-device exclusive rename, with no destination directory
                    // FD. A file created since validation must never be replaced.
                    guard renameatx_np(AT_FDCWD, staged.url.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                        throw ExportTarget.error("export_folder_unwritable")
                    }
                    result = destination
                }
                try hooks.afterSelectedPublish()
                // Do not report success for a different directory, a retargeted
                // result URL, or a file other than our staged inode.
                _ = try selected.verify(fileURL, excluding: roots, file: publishedIdentity)
                let verified = try selected.verify(result, excluding: roots, file: publishedIdentity)
                // File data was fsynced before publication; file-only authority
                // cannot fsync the parent directory. Do not claim name durability.
                return SavedExport(url: verified, name: verified.lastPathComponent,
                    folderLabel: label(verified.deletingLastPathComponent()), syncConfirmed: false)
            }
        }
        if let outcome {
            do { return try outcome.get() }
            catch let error as HyperDRError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { throw HyperDRError(code: "export_folder_unwritable", message: "Unable to publish selected file", messageDetail: String(describing: error)) }
        }
        throw HyperDRError(code: "export_folder_unwritable", message: "Unable to coordinate selected file", messageDetail: coordinationError?.localizedDescription)
    }

    /// External volumes may not supply an item-replacement directory. Direct
    /// writing is allowed only for a NEW file, so failure cannot destroy an
    /// existing file the user had agreed to replace.
    private static func copyDirectNewFile(_ source: SessionExportFile, to destination: URL,
                                          directory: Int32?, hooks: CopyHooks,
                                          verifyDirectory: () throws -> Void = {}) throws -> SavedExport {
        let name = destination.lastPathComponent
        try verifyDirectory()
        let output = directory.map { openat($0, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
            ?? Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ExportTarget.error("export_folder_unwritable") }
        var opened = stat()
        guard fstat(output, &opened) == 0 else { Darwin.close(output); throw ExportTarget.error("export_folder_unwritable") }
        var published = false
        defer {
            if !published {
                var named = stat()
                let found = directory.map { fstatat($0, name, &named, AT_SYMLINK_NOFOLLOW) }
                    ?? lstat(destination.path, &named)
                if found == 0,
                   named.st_dev == opened.st_dev, named.st_ino == opened.st_ino {
                    if let directory { unlinkat(directory, name, 0) }
                    else { unlink(destination.path) }
                }
            }
            Darwin.close(output)
        }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            try Task.checkCancellation()
            let count = hooks.read(source.descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ExportTarget.error("export_folder_unwritable") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count-offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw ExportTarget.error("export_folder_unwritable") }
                    offset += written
                }
            }
        }
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw ExportTarget.error("export_folder_unwritable") }
        var named = stat()
        let found = directory.map { fstatat($0, name, &named, AT_SYMLINK_NOFOLLOW) }
            ?? lstat(destination.path, &named)
        guard found == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino else {
            throw ExportTarget.error("export_folder_unwritable")
        }
        try verifyDirectory()
        // Verify after the data copy too. Without a parent FD, path identity
        // checks cannot make hostile non-cooperating renames atomic with open.
        // The held output FD nevertheless prevents redirecting ongoing writes.
        if directory == nil {
            let parent = try SelectedDestination(destination, excluding: [])
            guard parent.fileIdentity == FileIdentity(opened) else { throw ExportTarget.error("export_folder_unwritable") }
        }
        published = true
        let synced = directory.map { hooks.syncFolder($0) == 0 } ?? false
        if !synced { log.warning("Saved selected file but could not sync its folder") }
        return SavedExport(url: destination, name: name, folderLabel: label(destination.deletingLastPathComponent()), syncConfirmed: synced)
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
    private static func copy(_ source: SessionExportFile, to folder: URL, excluding roots: [URL],
                             hooks: CopyHooks) throws -> SavedExport {
        let directory = try openFolder(folder, excluding: roots)
        defer { Darwin.close(directory) }
        return try copy(source, directory: directory, hooks: hooks)
    }

    private static func copy(_ source: SessionExportFile, directory: Int32, hooks: CopyHooks) throws -> SavedExport {
        let input = source.descriptor
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw error("source_missing") }
        let temporary = ".hyperdr-export-\(UUID().uuidString)"
        guard mkdirat(directory, temporary, 0o700) == 0 else { throw error("export_folder_unwritable") }
        // Without a verified descriptor the directory cannot be cleaned by
        // identity; remove the name we just created only if it is still an
        // empty directory (AT_REMOVEDIR), so nothing with contents is touched.
        let staging = hooks.openStaging(directory, temporary)
        guard staging >= 0 else {
            unlinkat(directory, temporary, AT_REMOVEDIR)
            throw error("export_folder_unwritable")
        }
        var stagingInfo = stat()
        guard fstat(staging, &stagingInfo) == 0, stagingInfo.st_uid == geteuid(),
              stagingInfo.st_mode & 0o777 == 0o700 else {
            Darwin.close(staging)
            unlinkat(directory, temporary, AT_REMOVEDIR)
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
            let count = hooks.read(input, &buffer, buffer.count)
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
        // The file is already published under `name`. Reporting a failure now
        // would make the user retry and get "name (2)"; report success and say
        // the folder sync was not confirmed.
        let synced = hooks.syncFolder(directory) == 0
        if !synced {
            let reason = String(cString: strerror(errno))
            log.warning("Saved \(name, privacy: .public) but could not sync its folder: \(reason, privacy: .public)")
        }
        return SavedExport(url: canonical.appendingPathComponent(name), name: name,
                           folderLabel: label(canonical), syncConfirmed: synced)
    }
}

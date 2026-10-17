import CryptoKit
import Darwin
import Foundation
import HyperDREngine

public struct SessionID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    public var isValid: Bool { rawValue.count == 32 && rawValue.allSatisfy(\.isHexDigit) }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self).lowercased()
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ExportID: Sendable, Hashable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    public var isValid: Bool { rawValue.count == 32 && rawValue.allSatisfy(\.isHexDigit) }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self).lowercased()
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PhotoSession: Sendable, Identifiable, Hashable {
    public let id: SessionID
    public let sourceURL: URL
    public let displayName: String
    public let byteCount: Int64
    public let sha256: String
    public let format: InputFormat

    public init(id: SessionID, sourceURL: URL, displayName: String, byteCount: Int64,
                sha256: String, format: InputFormat) {
        self.id = id
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.format = format
    }
}

public struct ExportRecord: Sendable, Codable, Equatable {
    public let id: ExportID
    public let name: String
    public let byteCount: Int64
    public let createdAt: Date
    public let sourceDigest: String
    public let options: [String: JSONValue]
    public let reportJSON: Data
}

public enum SessionResource: String, Sendable, Codable {
    case luts
    case rawProfiles = "raw-profiles"
    case rawLooks = "raw-looks"
    case lensProfiles = "lens-profiles"
}

protocol SecurityScopedAccess: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SystemSecurityScopedAccess: SecurityScopedAccess {
    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Balances a security-scope start/stop pair. The lease owns the URL the system
/// actually granted access to; canonical filesystem paths are only used for
/// identity and containment checks.
final class SecurityScopeLease: @unchecked Sendable {
    let url: URL
    private let access: any SecurityScopedAccess
    private let lock = NSLock()
    private var active: Bool

    init(url: URL, access: any SecurityScopedAccess) {
        self.url = url
        self.access = access
        self.active = access.startAccessing(url)
    }

    func stop() {
        lock.withLock {
            guard active else { return }
            active = false
            access.stopAccessing(url)
        }
    }

    deinit { stop() }
}

/// One photo session on disk. The source file is never copied; a security-scoped
/// bookmark is the durable reference and access is held while the session is open.
public actor SessionStore {
    private struct StoredSession: Codable {
        var id: SessionID
        var sourcePath: String
        var sourceBookmark: Data
        var displayName: String
        var byteCount: Int64
        var modifiedAt: Int64
        var sha256: String
        var format: InputFormat
        var createdAt: Date
        var lastUsedAt: Date
    }
    private struct LastSession: Codable { let sessionID: SessionID }
    private struct PendingExport: Codable {
        let id: ExportID
        let options: [String: JSONValue]
        let sourceDigest: String
    }
    private struct OpenSession {
        let url: URL
        let lease: SecurityScopeLease
        let session: PhotoSession
        let modifiedAt: Int64
        let generation: UUID
        /// When `lastUsedAt` was last written to disk. Refreshes happen on every
        /// preview request, so persisting each one would rewrite session.json
        /// (and its inode) at slider speed.
        var lastPersistedAt: Date
    }

    /// At most one `lastUsedAt` flush per session per window; a changed source
    /// is always written immediately.
    static let lastUsedPersistInterval: TimeInterval = 60
    /// One in-flight activation or open. Waiters are tracked so the shared
    /// work is cancelled only when every caller has gone away; a single
    /// cancelled waiter must not break the other waiters.
    private final class FlightState: @unchecked Sendable {
        let token: UUID
        let task: Task<PhotoSession, Error>
        var waiters: [UUID: Bool] = [:]

        init(token: UUID, task: Task<PhotoSession, Error>) {
            self.token = token
            self.task = task
        }
    }
    private struct CachedDigest {
        let size: Int64
        let modifiedAt: Int64
        let digest: String
    }

    private let supportDirectory: URL
    private let sessionsDirectory: URL
    private let sessionsDevice: dev_t
    private let cacheDirectory: URL
    private let sessionTTL: TimeInterval
    private let decodeCacheMaxAge: TimeInterval
    private let decodeCacheMaxBytes: Int64
    private let formats: InputFormats
    private let access: any SecurityScopedAccess
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var openSessions: [SessionID: OpenSession] = [:]
    private var activating: [SessionID: FlightState] = [:]
    private var openingFlights: [String: FlightState] = [:]
    private var openingSessions: Set<SessionID> = []
    private var openingPaths: Set<String> = []
    private var exporting: Set<SessionID> = []
    private var digestCache: [String: CachedDigest] = [:]

    public init(configuration: KitConfiguration, formats: InputFormats) {
        self.init(configuration: configuration, formats: formats,
                  decodeCacheMaxAge: 7 * 24 * 60 * 60, decodeCacheMaxBytes: 4 << 30)
    }

    internal init(configuration: KitConfiguration, formats: InputFormats,
                  decodeCacheMaxAge: TimeInterval, decodeCacheMaxBytes: Int64,
                  access: any SecurityScopedAccess = SystemSecurityScopedAccess()) {
        supportDirectory = configuration.supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        sessionsDirectory = supportDirectory.appendingPathComponent("sessions", isDirectory: true)
        cacheDirectory = configuration.cacheDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("decode-cache", isDirectory: true)
        sessionTTL = configuration.sessionTTL.timeInterval
        self.decodeCacheMaxAge = decodeCacheMaxAge
        self.decodeCacheMaxBytes = decodeCacheMaxBytes
        self.formats = formats
        self.access = access
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
        try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Record the trusted device before any request can create a session.
        // Recursive removal refuses to cross onto a different device, so a
        // mounted disk image inside an export cannot be emptied by mistake.
        var rootInfo = stat()
        let status = sessionsDirectory.path.withCString {
            fstatat(AT_FDCWD, $0, &rootInfo, 0)
        }
        sessionsDevice = status == 0 ? rootInfo.st_dev : 0
    }

    // MARK: - Open / restore / close

    public func open(_ url: URL) async throws -> PhotoSession {
        guard url.isFileURL else {
            throw HyperDRError(code: "unsupported_format", message: "The source is not a file URL")
        }
        do { try ensureDirectories() }
        catch { throw publicError(error) }

        // Apple grants access to the URL that came from the picker, not to a
        // path derived from it. Lease the original URL before canonicalizing,
        // statting or probing the file.
        let lease = SecurityScopeLease(url: url, access: access)
        var leaseOwnedByCaller = true
        defer { if leaseOwnedByCaller { lease.stop() } }
        do {
            let source = try canonicalURL(url)
            // Concurrent opens of the same canonical path share one digest,
            // one activation and one lease.
            if let flight = openingFlights[source.path] {
                lease.stop()
                leaseOwnedByCaller = false
                return try await awaitOpenFlight(path: source.path, flight: flight)
            }
            let token = UUID()
            openingPaths.insert(source.path)
            let task = Task { [weak self] in
                guard let self else {
                    throw HyperDRError(code: "internal_error", message: "Session store was released")
                }
                do {
                    let session = try await self.performOpen(source: source, originalURL: url,
                        lease: lease, token: token)
                    await self.finishOpen(path: source.path, token: token)
                    return session
                } catch {
                    await self.finishOpen(path: source.path, token: token)
                    throw error
                }
            }
            let flight = FlightState(token: token, task: task)
            openingFlights[source.path] = flight
            // Ownership moved to the shared flight. A cancelled creator must
            // not stop a lease that a surviving waiter will receive as an
            // OpenSession.
            leaseOwnedByCaller = false
            return try await awaitOpenFlight(path: source.path, flight: flight)
        } catch {
            throw publicError(error)
        }
    }

    private func performOpen(source: URL, originalURL: URL, lease: SecurityScopeLease,
                             token: UUID) async throws -> PhotoSession {
        do {
            let (size, modifiedAt) = try fileFacts(source)
            let format = try formats.classify(source)
            let digest = try await digest(for: source, size: size, modifiedAt: modifiedAt)
            guard openingFlights[source.path]?.token == token, !Task.isCancelled else {
                throw CancellationError()
            }
            let bookmark = try makeBookmark(originalURL)
            let now = Date()
            let stored: StoredSession
            if var reusable = try reusableSession(path: source.path, digest: digest, now: now) {
                reusable.sourceBookmark = bookmark
                reusable.byteCount = size
                reusable.modifiedAt = modifiedAt
                reusable.format = format
                reusable.lastUsedAt = now
                try save(reusable)
                stored = reusable
            } else {
                let id = newSessionID()
                let directory = try sessionDirectory(id)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try createResourceDirectories(directory)
                let created = StoredSession(id: id, sourcePath: source.path, sourceBookmark: bookmark,
                    displayName: source.lastPathComponent, byteCount: size, modifiedAt: modifiedAt,
                    sha256: digest, format: format, createdAt: now, lastUsedAt: now)
                try save(created)
                stored = created
            }
            guard !Task.isCancelled else { throw CancellationError() }
            try writeLastSession(stored.id)
            let session = photoSession(stored, url: source)
            if let existing = openSessions[stored.id] {
                lease.stop()
                openSessions[stored.id] = OpenSession(url: existing.url, lease: existing.lease,
                    session: session, modifiedAt: modifiedAt, generation: existing.generation,
                    lastPersistedAt: existing.lastPersistedAt)
            } else {
                openSessions[stored.id] = OpenSession(url: source, lease: lease,
                    session: session, modifiedAt: modifiedAt, generation: UUID(),
                    lastPersistedAt: now)
            }
            return session
        } catch {
            lease.stop()
            throw error
        }
    }

    private func finishOpen(path: String, token: UUID) {
        guard openingFlights[path]?.token == token else { return }
        openingFlights.removeValue(forKey: path)
        openingPaths.remove(path)
    }

    private func awaitOpenFlight(path: String, flight: FlightState) async throws -> PhotoSession {
        let waiter = UUID()
        flight.waiters[waiter] = false
        defer { releaseOpenWaiter(path: path, flight: flight, waiter: waiter) }
        let session = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.cancelOpenWaiter(path: path, flight: flight, waiter: waiter) }
        }
        if Task.isCancelled { throw CancellationError() }
        return session
    }

    private func cancelOpenWaiter(path: String, flight: FlightState, waiter: UUID) {
        guard openingFlights[path]?.token == flight.token,
              flight.waiters[waiter] == false else { return }
        flight.waiters[waiter] = true
        if flight.waiters.values.allSatisfy({ $0 }) { flight.task.cancel() }
    }

    private func releaseOpenWaiter(path: String, flight: FlightState, waiter: UUID) {
        flight.waiters.removeValue(forKey: waiter)
        if flight.waiters.isEmpty, openingFlights[path]?.token == flight.token {
            openingFlights.removeValue(forKey: path)
            openingPaths.remove(path)
        }
    }

    public func restoreLast() async -> PhotoSession? {
        guard let id = readLastSession() else { return nil }
        do {
            let stored = try loadStored(id)
            guard stored.lastUsedAt >= Date().addingTimeInterval(-sessionTTL) else {
                clearLastSession()
                return nil
            }
            return try await session(id)
        } catch {
            clearLastSession()
            return nil
        }
    }

    public func session(_ id: SessionID) async throws -> PhotoSession {
        if let open = openSessions[id] {
            do { return try await refreshOpen(open, id: id) }
            catch { throw publicError(error) }
        }
        let stored: StoredSession
        do { stored = try loadStored(id) }
        catch { throw publicError(error) }

        if let flight = activating[id] {
            do { return try await awaitActivation(id: id, flight: flight) }
            catch { throw publicError(error) }
        }

        let token = UUID()
        openingSessions.insert(id)
        let task = Task { [weak self] in
            guard let self else {
                throw HyperDRError(code: "internal_error", message: "Session store was released")
            }
            do {
                let session = try await self.activate(stored, id: id, token: token)
                await self.finishActivation(id: id, token: token)
                return session
            } catch {
                await self.finishActivation(id: id, token: token)
                throw error
            }
        }
        let flight = FlightState(token: token, task: task)
        activating[id] = flight
        do { return try await awaitActivation(id: id, flight: flight) }
        catch { throw publicError(error) }
    }

    public func close(_ id: SessionID) async {
        if let flight = activating.removeValue(forKey: id) { flight.task.cancel() }
        openingSessions.remove(id)
        guard let open = openSessions.removeValue(forKey: id) else { return }
        open.lease.stop()
        // Flush the end of the session once; refreshes are throttled.
        if var stored = try? loadStored(id) {
            stored.lastUsedAt = Date()
            try? save(stored)
        }
    }

    private func finishActivation(id: SessionID, token: UUID) {
        guard activating[id]?.token == token else { return }
        activating.removeValue(forKey: id)
        openingSessions.remove(id)
    }

    private func awaitActivation(id: SessionID, flight: FlightState) async throws -> PhotoSession {
        let waiter = UUID()
        flight.waiters[waiter] = false
        defer { releaseActivationWaiter(id: id, flight: flight, waiter: waiter) }
        let session = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.cancelActivationWaiter(id: id, flight: flight, waiter: waiter) }
        }
        if Task.isCancelled { throw CancellationError() }
        return session
    }

    private func cancelActivationWaiter(id: SessionID, flight: FlightState, waiter: UUID) {
        guard activating[id]?.token == flight.token,
              flight.waiters[waiter] == false else { return }
        flight.waiters[waiter] = true
        if flight.waiters.values.allSatisfy({ $0 }) { flight.task.cancel() }
    }

    private func releaseActivationWaiter(id: SessionID, flight: FlightState, waiter: UUID) {
        flight.waiters.removeValue(forKey: waiter)
        if flight.waiters.isEmpty, activating[id]?.token == flight.token {
            activating.removeValue(forKey: id)
            openingSessions.remove(id)
        }
    }

    // MARK: - Cleanup

    public func cleanupExpired(now: Date = Date()) async -> Int {
        let cutoff = now.addingTimeInterval(-sessionTTL)
        let root: URL
        do { root = try sessionsRoot() }
        catch { return 0 }
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for directory in directories {
            let id = SessionID(rawValue: directory.lastPathComponent)
            guard id.isValid, openSessions[id] == nil, activating[id] == nil,
                  !openingSessions.contains(id), !exporting.contains(id) else { continue }
            guard let stored = try? loadStored(id) else { continue }
            guard !openingPaths.contains(stored.sourcePath) else { continue }
            cleanupAbandonedExports(id)
            guard !hasPendingExport(id) else { continue }
            guard stored.lastUsedAt < cutoff else { continue }
            do {
                try removeSessionDirectory(id)
                digestCache.removeValue(forKey: stored.sourcePath)
                if readLastSession() == id { clearLastSession() }
                removed += 1
            } catch { continue }
        }
        _ = trimDecodeCache(now: now)
        return removed
    }

    internal func trimDecodeCache(now: Date = Date()) -> Int {
        guard let enumerator = fileManager.enumerator(at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return 0 }
        var entries: [(url: URL, modified: Date, size: Int64)] = []
        for case let url as URL in enumerator {
            let attrs = try? fileManager.attributesOfItem(atPath: url.path)
            guard attrs?[.type] as? FileAttributeType == .typeRegular else { continue }
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = attrs?[.modificationDate] as? Date ?? .distantPast
            entries.append((url, modified, size))
        }
        let oldestAllowed = now.addingTimeInterval(-decodeCacheMaxAge)
        var removed = 0
        var total: Int64 = 0
        var remaining: [(url: URL, modified: Date, size: Int64)] = []
        for entry in entries {
            if entry.modified < oldestAllowed {
                do { try fileManager.removeItem(at: entry.url); removed += 1 }
                catch { remaining.append(entry); total += entry.size }
            } else {
                remaining.append(entry)
                total += entry.size
            }
        }
        for entry in remaining.sorted(by: { $0.modified < $1.modified }) where total > decodeCacheMaxBytes {
            do { try fileManager.removeItem(at: entry.url); total -= entry.size; removed += 1 }
            catch { continue }
        }
        return removed
    }

    // MARK: - Exports

    public func prepareExport(_ id: SessionID, options: [String: JSONValue]) async throws -> (id: ExportID, directory: URL) {
        let session = try await self.session(id)
        let exportID = newExportID()
        do {
            let folder = try exportDirectory(id, export: exportID)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let pending = PendingExport(id: exportID, options: options, sourceDigest: session.sha256)
            exporting.insert(id)
            do {
                try write(pending, to: folder.appendingPathComponent("pending.json"))
                return (exportID, folder)
            } catch {
                try? removeExportDirectory(id, export: exportID)
                exporting.remove(id)
                throw error
            }
        } catch {
            throw publicError(error)
        }
    }

    public func publishExport(_ id: SessionID, export: ExportID,
                              report: ConvertReport) async throws -> ExportRecord {
        defer { exporting.remove(id) }
        do {
            let folder = try exportDirectory(id, export: export)
            let folderFD = try openExportDirectoryFD(id, export: export)
            defer { Darwin.close(folderFD) }
            guard let pendingData = readFile(named: "pending.json", in: folderFD),
                  let pending = try? decoder.decode(PendingExport.self, from: pendingData),
                  pending.id == export else {
                throw HyperDRError(code: "internal_error",
                    message: "The export has no valid pending manifest")
            }
            guard let successful = report.files.first(where: { $0.success }) else {
                throw HyperDRError(code: "internal_error",
                    message: "The conversion report has no successful output")
            }
            let target = try containedURL(URL(fileURLWithPath: successful.output), in: folder)
            guard target.deletingLastPathComponent().path == folder.path else {
                throw HyperDRError(code: "invalid_options",
                    message: "The conversion report points outside the export directory")
            }
            let name = target.lastPathComponent
            guard isSafeComponent(name), !name.contains("\\") else {
                throw HyperDRError(code: "invalid_options",
                    message: "The conversion report uses an invalid output name")
            }
            var info = stat()
            guard fstatat(folderFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else {
                throw HyperDRError(code: "internal_error",
                    message: "The conversion result is not a regular file")
            }
            let fileSize = Int64(info.st_size)
            guard fileSize > 0 else {
                throw HyperDRError(code: "internal_error",
                    message: "The conversion produced no result file")
            }
            let record = ExportRecord(id: export, name: name,
                byteCount: fileSize, createdAt: Date(), sourceDigest: pending.sourceDigest,
                options: pending.options, reportJSON: report.json)
            let encoded: Data
            do { encoded = try encoder.encode(record) }
            catch {
                throw HyperDRError(code: "internal_error",
                    message: "Unable to encode the export manifest: \(error.localizedDescription)")
            }
            // Write the final manifest in place, then rename it within the
            // same directory. A crash before the rename leaves a promotable
            // final manifest in pending.json.
            try writeAtomically(encoded, named: "pending.json", in: folderFD)
            var resultInfo = stat()
            guard fstatat(folderFD, "result.json", &resultInfo, AT_SYMLINK_NOFOLLOW) != 0 else {
                throw HyperDRError(code: "internal_error", message: "Export is already published")
            }
            guard Darwin.renameat(folderFD, "pending.json", folderFD, "result.json") == 0 else {
                throw posixError("renameat", "result.json")
            }
            return record
        } catch {
            throw publicError(error)
        }
    }

    public func discardExport(_ id: SessionID, export: ExportID) async {
        defer { exporting.remove(id) }
        guard id.isValid, export.isValid,
              let root = try? openDirectory(sessionsDirectory) else { return }
        defer { Darwin.close(root) }
        guard let session = try? openDirectory(named: id.rawValue, in: root) else { return }
        defer { Darwin.close(session) }
        guard let exports = try? openDirectory(named: "exports", in: session) else { return }
        defer { Darwin.close(exports) }
        do { try requireTrustedDevice(exports) }
        catch { return }
        guard let folder = try? openDirectory(named: export.rawValue, in: exports) else {
            // Unlink a symlinked or otherwise bogus export entry without ever
            // traversing it; a missing entry is simply a no-op.
            try? removeEntry(named: export.rawValue, in: exports)
            return
        }
        do { try verifyTrustedTree(folder) }
        catch {
            // A mounted volume inside the export is not ours to clean up.
            Darwin.close(folder)
            return
        }
        if regularFileSize(named: "result.json", in: folder) != nil {
            try? removeEntry(named: "pending.json", in: folder)
            Darwin.close(folder)
            return
        }
        Darwin.close(folder)
        try? removeEntry(named: export.rawValue, in: exports)
    }

    public func exports(for id: SessionID) async -> [ExportRecord] {
        guard let stored = try? loadStored(id) else { return [] }
        let digest: String
        if let open = openSessions[id] {
            do { digest = try await refreshOpen(open, id: id).sha256 } catch { return [] }
        } else {
            do { digest = try await currentDigest(stored) } catch { return [] }
        }
        return loadExportRecords(id).filter { $0.sourceDigest == digest }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func resultURL(_ id: SessionID, export: ExportID?) async throws -> URL {
        let records = await exports(for: id)
        let record: ExportRecord
        if let export {
            guard let found = records.first(where: { $0.id == export }) else {
                throw HyperDRError(code: "source_missing", message: "Export \(export.rawValue) does not exist")
            }
            record = found
        } else {
            guard let latest = records.first else {
                throw HyperDRError(code: "source_missing", message: "No export exists for this session")
            }
            record = latest
        }
        guard let target = resultFileURL(id, record: record) else {
            throw HyperDRError(code: "source_missing", message: "The exported file is missing")
        }
        return target
    }

    public func resourceDirectory(_ id: SessionID, _ kind: SessionResource) async throws -> URL {
        do {
            let directory = try sessionDirectory(id)
            guard fileManager.fileExists(atPath: directory.appendingPathComponent("session.json").path) else {
                throw HyperDRError(code: "session_expired", message: "Session \(id.rawValue) no longer exists")
            }
            let target = try containedURL(directory.appendingPathComponent(kind.rawValue, isDirectory: true),
                                          in: directory)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            return target
        } catch {
            throw publicError(error)
        }
    }

    // MARK: - Path containment

    private func sessionsRoot() throws -> URL {
        let root = sessionsDirectory.resolvingSymlinksInPath().standardizedFileURL
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        _ = try sessionsRoot()
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw HyperDRError(code: "source_unreadable",
                message: "Source file is missing or is not a regular file: \(resolved.path)")
        }
        return resolved
    }

    private func fileAttributes(_ url: URL) throws -> (type: FileAttributeType, size: Int64, modified: Date) {
        let values: [FileAttributeKey: Any]
        do { values = try fileManager.attributesOfItem(atPath: url.path) }
        catch {
            throw HyperDRError(code: "source_unreadable",
                message: "Unable to inspect \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let type = values[.type] as? FileAttributeType ?? .typeUnknown
        let size = (values[.size] as? NSNumber)?.int64Value ?? 0
        let modified = values[.modificationDate] as? Date ?? .distantPast
        return (type, size, modified)
    }

    private func fileFacts(_ url: URL) throws -> (size: Int64, modifiedAt: Int64) {
        let values = try fileAttributes(url)
        guard values.type == .typeRegular else {
            throw HyperDRError(code: "source_unreadable", message: "The source is not a regular file")
        }
        guard values.size > 0 else {
            throw HyperDRError(code: "file_empty", message: "The source file is empty")
        }
        return (values.size, Int64((values.modified.timeIntervalSince1970 * 1_000_000_000).rounded()))
    }

    private func pathComponents(_ url: URL) -> [String] { url.standardizedFileURL.pathComponents }

    private func isContained(_ target: URL, in root: URL) -> Bool {
        let targetParts = pathComponents(target)
        let rootParts = pathComponents(root)
        guard targetParts.count > rootParts.count else { return false }
        return Array(targetParts.prefix(rootParts.count)) == rootParts
    }

    private func ensureNoSymlinkComponents(root: URL, target: URL) throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let target = target.standardizedFileURL
        guard isContained(target, in: root) else {
            throw HyperDRError(code: "invalid_options", message: "Path escapes its session root")
        }
        let rootParts = pathComponents(root)
        let targetParts = pathComponents(target)
        var current = root
        for component in targetParts.dropFirst(rootParts.count) {
            current.appendPathComponent(component)
            // lstat every existing component; fileExists() follows a dangling
            // link and would let createDirectory() escape through it.
            guard let attrs = try? fileManager.attributesOfItem(atPath: current.path) else { break }
            if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                throw HyperDRError(code: "invalid_options", message: "Path crosses a symbolic link")
            }
        }
    }

    private func containedURL(_ target: URL, in root: URL) throws -> URL {
        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let standardTarget = target.standardizedFileURL
        guard isContained(standardTarget, in: realRoot) else {
            throw HyperDRError(code: "invalid_options", message: "Path escapes its session root")
        }
        try ensureNoSymlinkComponents(root: realRoot, target: standardTarget)
        let realTarget = standardTarget.resolvingSymlinksInPath().standardizedFileURL
        guard isContained(realTarget, in: realRoot) else {
            throw HyperDRError(code: "invalid_options", message: "Path escapes its session root")
        }
        return realTarget
    }

    private func sessionDirectory(_ id: SessionID) throws -> URL {
        guard id.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid session id: \(id.rawValue)")
        }
        let root = try sessionsRoot()
        return try containedURL(root.appendingPathComponent(id.rawValue, isDirectory: true), in: root)
    }

    private func exportDirectory(_ id: SessionID, export: ExportID) throws -> URL {
        guard export.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid export id: \(export.rawValue)")
        }
        let session = try sessionDirectory(id)
        let exports = try containedURL(session.appendingPathComponent("exports", isDirectory: true), in: session)
        return try containedURL(exports.appendingPathComponent(export.rawValue, isDirectory: true), in: session)
    }

    private func openExportDirectoryFD(_ id: SessionID, export: ExportID) throws -> Int32 {
        guard id.isValid, export.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid session or export id")
        }
        let root = try openDirectory(sessionsDirectory)
        defer { Darwin.close(root) }
        try requireTrustedDevice(root)
        let session = try openDirectory(named: id.rawValue, in: root)
        defer { Darwin.close(session) }
        try requireTrustedDevice(session)
        let exports = try openDirectory(named: "exports", in: session)
        defer { Darwin.close(exports) }
        try requireTrustedDevice(exports)
        let folder = try openDirectory(named: export.rawValue, in: exports)
        do { try requireTrustedDevice(folder) }
        catch {
            Darwin.close(folder)
            throw error
        }
        return folder
    }

    private func writeAtomically(_ data: Data, named name: String, in directory: Int32) throws {
        guard isSafeComponent(name) else {
            throw HyperDRError(code: "invalid_options", message: "Invalid file name: \(name)")
        }
        let temporary = ".\(name).\(UUID().uuidString).tmp"
        let fd = Darwin.openat(directory, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError("openat", temporary) }
        var failed = false
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count, !failed {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset)
                if written <= 0 { failed = true; break }
                offset += written
            }
        }
        if !failed { failed = Darwin.fsync(fd) != 0 }
        Darwin.close(fd)
        if failed {
            try? removeEntry(named: temporary, in: directory)
            throw posixError("write", temporary)
        }
        guard Darwin.renameat(directory, temporary, directory, name) == 0 else {
            try? removeEntry(named: temporary, in: directory)
            throw posixError("renameat", name)
        }
    }

    // MARK: - No-follow removal

    private func openDirectory(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open", url.lastPathComponent) }
        return fd
    }

    private func openDirectory(named name: String, in parent: Int32) throws -> Int32 {
        guard isSafeComponent(name) else {
            throw HyperDRError(code: "invalid_options", message: "Invalid directory name: \(name)")
        }
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("openat", name) }
        return fd
    }

    private func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private func posixError(_ operation: String, _ name: String) -> HyperDRError {
        HyperDRError(code: "internal_error",
            message: "\(operation) \(name) failed: \(String(cString: strerror(errno)))")
    }

    private func entryNames(in directory: Int32) -> [String] {
        // dup() shares the directory read offset with the original fd. Open
        // "at the directory" instead so repeated listings (verify then delete)
        // each start at the beginning.
        let reopened = Darwin.openat(directory, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard reopened >= 0 else { return [] }
        guard let stream = Darwin.fdopendir(reopened) else {
            Darwin.close(reopened)
            return []
        }
        defer { Darwin.closedir(stream) }
        var names: [String] = []
        while let entry = Darwin.readdir(stream) {
            var raw = entry.pointee.d_name
            let name = withUnsafePointer(to: &raw) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    private func removeContents(of directory: Int32) throws {
        for name in entryNames(in: directory) {
            try removeEntry(named: name, in: directory)
        }
    }

    /// Removes one directory entry relative to an open directory descriptor.
    /// The final component is never followed; directories are opened with
    /// O_NOFOLLOW and emptied through their own descriptor, so replacing any
    /// parent with a symlink cannot redirect the deletion outside the tree.
    private func removeEntry(named name: String, in directory: Int32) throws {
        guard isSafeComponent(name) else {
            throw HyperDRError(code: "invalid_options", message: "Invalid path component: \(name)")
        }
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw posixError("fstatat", name)
        }
        guard sessionsDevice != 0, info.st_dev == sessionsDevice else {
            throw HyperDRError(code: "internal_error",
                message: "Refusing to cross a mounted filesystem boundary")
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            let child = try openDirectory(named: name, in: directory)
            do { try removeContents(of: child) }
            catch {
                Darwin.close(child)
                throw error
            }
            Darwin.close(child)
            guard Darwin.unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                throw posixError("unlinkat", name)
            }
        } else {
            guard Darwin.unlinkat(directory, name, 0) == 0 else {
                throw posixError("unlinkat", name)
            }
        }
    }

    private func requireTrustedDevice(_ directory: Int32) throws {
        guard sessionsDevice != 0 else {
            throw HyperDRError(code: "internal_error",
                message: "The session root device is unknown; refusing to remove files")
        }
        var info = stat()
        guard fstat(directory, &info) == 0 else { throw posixError("fstat", "directory") }
        guard info.st_dev == sessionsDevice else {
            throw HyperDRError(code: "internal_error",
                message: "Refusing to cross a mounted filesystem boundary")
        }
    }

    /// Reject a tree that contains a mount point before deleting anything.
    /// removeEntry() repeats the device check per component for TOCTOU safety.
    private func verifyTrustedTree(_ directory: Int32) throws {
        try requireTrustedDevice(directory)
        for name in entryNames(in: directory) {
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard info.st_dev == sessionsDevice else {
                throw HyperDRError(code: "internal_error",
                    message: "Refusing to cross a mounted filesystem boundary")
            }
            let child = try openDirectory(named: name, in: directory)
            do { try verifyTrustedTree(child) }
            catch {
                Darwin.close(child)
                throw error
            }
            Darwin.close(child)
        }
    }

    private func removeSessionDirectory(_ id: SessionID) throws {
        guard id.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid session id: \(id.rawValue)")
        }
        let root = try openDirectory(sessionsDirectory)
        defer { Darwin.close(root) }
        try requireTrustedDevice(root)
        if let session = try? openDirectory(named: id.rawValue, in: root) {
            do { try verifyTrustedTree(session) }
            catch {
                Darwin.close(session)
                throw error
            }
            Darwin.close(session)
        }
        try removeEntry(named: id.rawValue, in: root)
    }

    private func removeExportDirectory(_ id: SessionID, export: ExportID) throws {
        guard id.isValid, export.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid session or export id")
        }
        let root = try openDirectory(sessionsDirectory)
        defer { Darwin.close(root) }
        try requireTrustedDevice(root)
        let session = try openDirectory(named: id.rawValue, in: root)
        defer { Darwin.close(session) }
        try requireTrustedDevice(session)
        let exports = try openDirectory(named: "exports", in: session)
        defer { Darwin.close(exports) }
        try requireTrustedDevice(exports)
        if let folder = try? openDirectory(named: export.rawValue, in: exports) {
            do { try verifyTrustedTree(folder) }
            catch {
                Darwin.close(folder)
                throw error
            }
            Darwin.close(folder)
        }
        try removeEntry(named: export.rawValue, in: exports)
    }

    private func regularFileSize(named name: String, in directory: Int32) -> Int64? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return Int64(info.st_size)
    }

    private func readFile(named name: String, in directory: Int32) -> Data? {
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }

    // MARK: - Export recovery

    private func cleanupAbandonedExports(_ id: SessionID) {
        guard id.isValid else { return }
        guard let root = try? openDirectory(sessionsDirectory) else { return }
        defer { Darwin.close(root) }
        guard let session = try? openDirectory(named: id.rawValue, in: root) else { return }
        defer { Darwin.close(session) }
        guard let exports = try? openDirectory(named: "exports", in: session) else {
            // A symlinked exports entry is never legitimate. Unlink the entry
            // itself; its destination is outside this session's tree.
            try? removeEntry(named: "exports", in: session)
            return
        }
        defer { Darwin.close(exports) }
        do { try verifyTrustedTree(exports) }
        catch { return }
        for name in entryNames(in: exports) {
            var info = stat()
            guard fstatat(exports, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            guard (info.st_mode & S_IFMT) == S_IFDIR else {
                try? removeEntry(named: name, in: exports)
                continue
            }
            guard let export = try? openDirectory(named: name, in: exports) else { continue }
            do { try verifyTrustedTree(export) }
            catch {
                Darwin.close(export)
                continue
            }
            let hasResult = regularFileSize(named: "result.json", in: export) != nil
            let hasPending = regularFileSize(named: "pending.json", in: export) != nil
            if hasResult {
                // result.json wins whenever both manifests are present.
                if hasPending { try? removeEntry(named: "pending.json", in: export) }
            } else if hasPending, promoteFinalManifest(named: name, in: export) {
                // publishExport writes the final manifest to pending.json and
                // then renames it. A crash in between is recoverable here.
            } else {
                Darwin.close(export)
                try? removeEntry(named: name, in: exports)
                continue
            }
            Darwin.close(export)
        }
    }

    private func promoteFinalManifest(named name: String, in export: Int32) -> Bool {
        guard let data = readFile(named: "pending.json", in: export),
              let record = try? decoder.decode(ExportRecord.self, from: data),
              record.id.rawValue == name,
              record.name == (record.name as NSString).lastPathComponent,
              isSafeComponent(record.name),
              !record.name.contains("\\"),
              regularFileSize(named: record.name, in: export) != nil else { return false }
        guard Darwin.renameat(export, "pending.json", export, "result.json") == 0 else {
            return false
        }
        return true
    }

    private func hasPendingExport(_ id: SessionID) -> Bool {
        guard id.isValid else { return true }
        guard let root = try? openDirectory(sessionsDirectory) else { return true }
        defer { Darwin.close(root) }
        guard let session = try? openDirectory(named: id.rawValue, in: root) else { return false }
        defer { Darwin.close(session) }
        guard let exports = try? openDirectory(named: "exports", in: session) else { return false }
        defer { Darwin.close(exports) }
        for name in entryNames(in: exports) where isSafeComponent(name) {
            guard let export = try? openDirectory(named: name, in: exports) else { continue }
            defer { Darwin.close(export) }
            if regularFileSize(named: "result.json", in: export) == nil,
               regularFileSize(named: "pending.json", in: export) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Activation / digest

    private func activate(_ initial: StoredSession, id: SessionID, token: UUID) async throws -> PhotoSession {
        let (url, stale) = try resolveBookmark(initial.sourceBookmark)
        // The resolved bookmark URL is the URL the security scope belongs to.
        // Lease it before resolving symlinks, statting or saving anything.
        let lease = SecurityScopeLease(url: url, access: access)
        do {
            guard activating[id]?.token == token else { throw CancellationError() }
            let source = try canonicalURL(url)
            let (size, modifiedAt) = try fileFacts(source)
            var stored = initial
            if size != stored.byteCount || modifiedAt != stored.modifiedAt || stored.sha256.isEmpty {
                let digest = try await digest(for: source, size: size, modifiedAt: modifiedAt)
                guard activating[id]?.token == token, !Task.isCancelled else {
                    throw CancellationError()
                }
                stored.sha256 = digest
                stored.byteCount = size
                stored.modifiedAt = modifiedAt
                stored.sourcePath = source.path
            }
            if stale { stored.sourceBookmark = try makeBookmark(url) }
            guard activating[id]?.token == token, !Task.isCancelled else {
                throw CancellationError()
            }
            stored.lastUsedAt = Date()
            try save(stored)
            let session = photoSession(stored, url: source)
            if let existing = openSessions[id] {
                if existing.session.sha256 == session.sha256 {
                    lease.stop()
                    return existing.session
                }
                existing.lease.stop()
            }
            openSessions[id] = OpenSession(url: source, lease: lease, session: session,
                modifiedAt: stored.modifiedAt, generation: UUID(), lastPersistedAt: Date())
            return session
        } catch {
            lease.stop()
            throw error
        }
    }

    private func refreshOpen(_ open: OpenSession, id: SessionID) async throws -> PhotoSession {
        let generation = open.generation
        guard fileManager.fileExists(atPath: open.url.path) else {
            throw HyperDRError(code: "source_missing", message: "The source file has moved or been deleted")
        }
        let (size, modifiedAt) = try fileFacts(open.url)
        var stored = try loadStored(id)
        guard openSessions[id]?.generation == generation, !Task.isCancelled else {
            throw CancellationError()
        }
        var sourceChanged = false
        if size != stored.byteCount || modifiedAt != stored.modifiedAt || stored.sha256.isEmpty {
            let digest = try await digest(for: open.url, size: size, modifiedAt: modifiedAt)
            guard openSessions[id]?.generation == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            sourceChanged = true
            stored.sha256 = digest
            stored.byteCount = size
            stored.modifiedAt = modifiedAt
            stored.sourcePath = open.url.path
        }
        // Do not write a captured generation back after an await: close() or a
        // replacement session may have invalidated it while hashing.
        guard let current = openSessions[id], current.generation == generation,
              !Task.isCancelled else {
            throw CancellationError()
        }
        let now = Date()
        let persist = sourceChanged
            || now.timeIntervalSince(current.lastPersistedAt) >= Self.lastUsedPersistInterval
        if persist {
            stored.lastUsedAt = now
            try save(stored)
        }
        let session = photoSession(stored, url: current.url)
        openSessions[id] = OpenSession(url: current.url, lease: current.lease, session: session,
            modifiedAt: stored.modifiedAt, generation: generation,
            lastPersistedAt: persist ? now : current.lastPersistedAt)
        return session
    }

    private func currentDigest(_ stored: StoredSession) async throws -> String {
        let (url, stale) = try resolveBookmark(stored.sourceBookmark)
        let lease = SecurityScopeLease(url: url, access: access)
        defer { lease.stop() }
        let source = try canonicalURL(url)
        let (size, modifiedAt) = try fileFacts(source)
        if size == stored.byteCount && modifiedAt == stored.modifiedAt && !stored.sha256.isEmpty {
            if stale {
                var refreshed = stored
                refreshed.sourceBookmark = try makeBookmark(url)
                try save(refreshed)
            }
            return stored.sha256
        }
        let digest = try await digest(for: source, size: size, modifiedAt: modifiedAt)
        var updated = stored
        updated.sha256 = digest
        updated.byteCount = size
        updated.modifiedAt = modifiedAt
        updated.sourcePath = source.path
        if stale { updated.sourceBookmark = try makeBookmark(url) }
        try save(updated)
        return digest
    }

    private func digest(for url: URL, size: Int64, modifiedAt: Int64) async throws -> String {
        if let cached = digestCache[url.path], cached.size == size, cached.modifiedAt == modifiedAt {
            return cached.digest
        }
        let digest = try await sha256(url)
        digestCache[url.path] = CachedDigest(size: size, modifiedAt: modifiedAt, digest: digest)
        return digest
    }

    internal func sha256(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    do { try Task.checkCancellation() }
                    catch { throw HyperDRError(code: "cancelled", message: "Source digest cancelled") }
                    let chunk: Data
                    do { chunk = try handle.read(upToCount: 1 << 20) ?? Data() }
                    catch {
                        throw HyperDRError(code: "source_unreadable",
                            message: "Unable to read source: \(error.localizedDescription)")
                    }
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            } catch let error as HyperDRError {
                throw error
            } catch {
                throw HyperDRError(code: "source_unreadable",
                    message: "Unable to read source: \(error.localizedDescription)")
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Persistence

    private func reusableSession(path: String, digest: String, now: Date) throws -> StoredSession? {
        guard let root = try? sessionsRoot(),
              let directories = try? fileManager.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        let cutoff = now.addingTimeInterval(-sessionTTL)
        var best: StoredSession?
        for directory in directories {
            let id = SessionID(rawValue: directory.lastPathComponent)
            guard id.isValid, let stored = try? loadStored(id),
                  stored.sourcePath == path, stored.sha256 == digest,
                  stored.lastUsedAt >= cutoff else { continue }
            if best == nil || stored.lastUsedAt > best!.lastUsedAt { best = stored }
        }
        return best
    }

    private func photoSession(_ stored: StoredSession, url: URL) -> PhotoSession {
        PhotoSession(id: stored.id, sourceURL: url, displayName: stored.displayName,
            byteCount: stored.byteCount, sha256: stored.sha256, format: stored.format)
    }

    private func newSessionID() -> SessionID {
        while true {
            let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let id = SessionID(rawValue: value)
            if !fileManager.fileExists(atPath: sessionsDirectory.appendingPathComponent(value).path) {
                return id
            }
        }
    }

    private func newExportID() -> ExportID {
        ExportID(rawValue: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    }

    private func createResourceDirectories(_ directory: URL) throws {
        for name in ["exports", SessionResource.luts.rawValue, SessionResource.rawProfiles.rawValue,
                     SessionResource.rawLooks.rawValue, SessionResource.lensProfiles.rawValue] {
            let target = try containedURL(directory.appendingPathComponent(name, isDirectory: true), in: directory)
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
    }

    private func loadStored(_ id: SessionID) throws -> StoredSession {
        let file = try sessionDirectory(id).appendingPathComponent("session.json")
        guard let stored = try? read(StoredSession.self, from: file), stored.id == id else {
            throw HyperDRError(code: "session_expired",
                message: "Session \(id.rawValue) no longer exists")
        }
        return stored
    }

    private func save(_ stored: StoredSession) throws {
        try write(stored, to: try sessionDirectory(stored.id).appendingPathComponent("session.json"))
    }

    private func writeLastSession(_ id: SessionID) throws {
        try write(LastSession(sessionID: id), to: supportDirectory.appendingPathComponent("last-session.json"))
    }

    private func readLastSession() -> SessionID? {
        let file = supportDirectory.appendingPathComponent("last-session.json")
        return (try? read(LastSession.self, from: file))?.sessionID
    }

    private func clearLastSession() {
        try? fileManager.removeItem(at: supportDirectory.appendingPathComponent("last-session.json"))
    }

    private func loadExportRecords(_ id: SessionID) -> [ExportRecord] {
        guard let session = try? sessionDirectory(id),
              let exports = try? containedURL(session.appendingPathComponent("exports", isDirectory: true), in: session),
              let folders = try? fileManager.contentsOfDirectory(at: exports,
                  includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var records: [ExportRecord] = []
        for folder in folders {
            let attrs = try? fileManager.attributesOfItem(atPath: folder.path)
            guard attrs?[.type] as? FileAttributeType == .typeDirectory else { continue }
            guard let record = try? read(ExportRecord.self, from: folder.appendingPathComponent("result.json")),
                  record.id.rawValue == folder.lastPathComponent,
                  resultFileURL(id, record: record) != nil else { continue }
            records.append(record)
        }
        return records
    }

    private func resultFileURL(_ id: SessionID, record: ExportRecord) -> URL? {
        guard record.name == (record.name as NSString).lastPathComponent,
              !record.name.isEmpty, record.name != ".", record.name != "..",
              !record.name.contains("/"), !record.name.contains("\\") else { return nil }
        guard let folder = try? exportDirectory(id, export: record.id) else { return nil }
        let target = folder.appendingPathComponent(record.name)
        guard let validated = try? containedURL(target, in: folder),
              validated.deletingLastPathComponent().path == folder.path else { return nil }
        let attrs = try? fileManager.attributesOfItem(atPath: validated.path)
        guard attrs?[.type] as? FileAttributeType == .typeRegular else { return nil }
        return validated
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            throw HyperDRError(code: "internal_error",
                message: "Unable to write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do { return try decoder.decode(type, from: Data(contentsOf: url)) }
        catch {
            throw HyperDRError(code: "internal_error",
                message: "Unable to read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func resolveBookmark(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            // Keep the exact URL the scope was resolved for; callers lease it
            // before standardizing or otherwise touching the file system.
            return (url, stale)
        } catch {
            throw HyperDRError(code: "source_missing", message: "The source bookmark is no longer valid")
        }
    }

    private func makeBookmark(_ url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope],
                includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            throw HyperDRError(code: "source_unreadable",
                message: "Unable to create a bookmark for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func publicError(_ error: Error) -> HyperDRError {
        if let error = error as? HyperDRError { return error }
        if error is CancellationError {
            return HyperDRError(code: "cancelled", message: "Session operation cancelled")
        }
        return HyperDRError(code: "source_unreadable",
            message: "Session operation failed: \(error.localizedDescription)")
    }
}

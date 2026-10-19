import CryptoKit
import Darwin
import Foundation
import HyperDREngine
import os

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

public enum RestoreOutcome: Sendable {
    case none
    case restored(PhotoSession)
    case unavailable(HyperDRError)
}

public struct ExportRecord: Sendable, Codable, Equatable {
    public let id: ExportID
    public let name: String
    public let byteCount: Int64
    public let createdAt: Date
    public let sourceDigest: String
    public let options: [String: JSONValue]
    public let reportJSON: Data
    public let sequence: Int
    public let key: ExportKey
    public let frame: ExportFrameRecord?
    /// Loaded from saved.json; publication never rewrites result.json.
    public internal(set) var saved: SavedMark? = nil
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

/// A validated open file, owned through asynchronous copying. Paths are labels;
/// neither callers nor the copier reopen the source by its absolute path.
final class SessionExportFile: @unchecked Sendable {
    let descriptor: Int32
    let name: String
    init(descriptor: Int32, name: String) { self.descriptor = descriptor; self.name = name }
    deinit { Darwin.close(descriptor) }
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
        // Absent in records written before the ctime check: such a record
        // never matches, so its source is hashed once more and then recorded.
        var changedAt: Int64? = nil
        var device: Int64? = nil
        var inode: UInt64? = nil

        var facts: SourceFacts? {
            guard let changedAt, let device, let inode else { return nil }
            return SourceFacts(size: byteCount, modifiedAt: modifiedAt, changedAt: changedAt,
                               device: device, inode: inode)
        }
        mutating func record(_ facts: SourceFacts) {
            byteCount = facts.size
            modifiedAt = facts.modifiedAt
            changedAt = facts.changedAt
            device = facts.device
            inode = facts.inode
        }
    }
    /// What says the source's bytes are unchanged without reading them. Stricter
    /// than the Python reference (`session.py`, size + mtime_ns): the ctime
    /// cannot be set back from user space, so a same-size rewrite that restores
    /// the mtime is still noticed. A chmod or xattr change also moves the ctime
    /// and costs one more hash; that is accepted.
    struct SourceFacts: Equatable {
        let size: Int64
        let modifiedAt: Int64
        let changedAt: Int64
        let device: Int64
        let inode: UInt64
    }
    private struct LastSession: Codable { let sessionID: SessionID }
    private struct PendingExport: Codable {
        let id: ExportID
        let options: [String: JSONValue]
        let sourceDigest: String
        let frame: ExportFrameRecord?
        let key: ExportKey
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
        // An activation lease is retained only after a live caller claims it.
        var claimed = false

        init(token: UUID, task: Task<PhotoSession, Error>) {
            self.token = token
            self.task = task
        }
    }
    private struct CachedDigest {
        let facts: SourceFacts
        let digest: String
    }

    private let supportDirectory: URL
    private let sessionsDirectory: URL
    private let sessionsDevice: dev_t
    typealias OpenExportLeaf = @Sendable (Int32, String, Int32) -> Int32
    private let openExportLeaf: OpenExportLeaf
    private let exportRoot: SessionExportFile?
    private let cacheDirectory: URL
    private let exportHistoryLimit: Int
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
    private var exporting: [SessionID: Set<ExportID>] = [:]
    private var digestCache: [String: CachedDigest] = [:]
    /// How many times a source was read in full to hash it (tests).
    private(set) var digestComputations = 0

    public init(configuration: KitConfiguration, formats: InputFormats) {
        self.init(configuration: configuration, formats: formats,
                  decodeCacheMaxAge: 7 * 24 * 60 * 60, decodeCacheMaxBytes: 4 << 30)
    }

    internal init(configuration: KitConfiguration, formats: InputFormats,
                  decodeCacheMaxAge: TimeInterval, decodeCacheMaxBytes: Int64,
                  access: any SecurityScopedAccess = SystemSecurityScopedAccess(),
                  openExportLeaf: @escaping OpenExportLeaf = { openat($0, $1, $2) }) {
        self.openExportLeaf = openExportLeaf
        supportDirectory = configuration.supportDirectory.resolvingSymlinksInPath().standardizedFileURL
        sessionsDirectory = supportDirectory.appendingPathComponent("sessions", isDirectory: true)
        cacheDirectory = configuration.cacheDirectory.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("decode-cache", isDirectory: true)
        exportHistoryLimit = max(1, configuration.exportHistoryLimit)
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
        let descriptor = Darwin.open(sessionsDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        exportRoot = descriptor >= 0 ? SessionExportFile(descriptor: descriptor, name: "") : nil
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
            let facts = try fileFacts(source)
            let format = try formats.classify(source)
            let digest = try await digest(for: source, facts: facts)
            guard openingFlights[source.path]?.token == token, !Task.isCancelled else {
                throw CancellationError()
            }
            let bookmark = try makeBookmark(originalURL)
            let now = Date()
            let stored: StoredSession
            if var reusable = try reusableSession(path: source.path, digest: digest, now: now) {
                reusable.sourceBookmark = bookmark
                reusable.record(facts)
                reusable.format = format
                reusable.lastUsedAt = now
                try save(reusable)
                stored = reusable
            } else {
                let id = newSessionID()
                let directory = try sessionDirectory(id)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try createResourceDirectories(directory)
                var created = StoredSession(id: id, sourcePath: source.path, sourceBookmark: bookmark,
                    displayName: source.lastPathComponent, byteCount: facts.size,
                    modifiedAt: facts.modifiedAt, sha256: digest, format: format,
                    createdAt: now, lastUsedAt: now)
                created.record(facts)
                try save(created)
                stored = created
            }
            guard !Task.isCancelled else { throw CancellationError() }
            try writeLastSession(stored.id)
            let session = photoSession(stored, url: source)
            if let existing = openSessions[stored.id] {
                lease.stop()
                openSessions[stored.id] = OpenSession(url: existing.url, lease: existing.lease,
                    session: session, modifiedAt: facts.modifiedAt, generation: existing.generation,
                    lastPersistedAt: existing.lastPersistedAt)
            } else {
                openSessions[stored.id] = OpenSession(url: source, lease: lease,
                    session: session, modifiedAt: facts.modifiedAt, generation: UUID(),
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
        if case .restored(let session) = await restoreLastOutcome() { return session }
        return nil
    }

    /// An absent or expired history is normal; an inaccessible source is reported
    /// once, then removed from history so launch does not repeatedly alert.
    public func restoreLastOutcome() async -> RestoreOutcome {
        guard let id = readLastSession() else { return .none }
        do {
            try Task.checkCancellation()
            let stored = try loadStored(id)
            guard stored.lastUsedAt >= Date().addingTimeInterval(-sessionTTL) else {
                if readLastSession() == id { clearLastSession() }
                return .none
            }
            // session checks cancellation at the ownership handoff. Do not
            // reject an already claimed lease after that return boundary.
            return .restored(try await session(id))
        } catch {
            // Another open may have replaced the history while activation awaited.
            // Cancellation must preserve the history for the next launch.
            let failure = publicError(error)
            if failure.code != "cancelled", readLastSession() == id { clearLastSession() }
            return .unavailable(failure)
        }
    }

    public func session(_ id: SessionID) async throws -> PhotoSession {
        if Task.isCancelled { throw publicError(CancellationError()) }
        // Join even a completed activation until its callers have claimed or
        // released it; the openSessions entry still belongs to that flight.
        if let flight = activating[id] {
            do { return try await awaitActivation(id: id, flight: flight) }
            catch { throw publicError(error) }
        }
        if let open = openSessions[id] {
            do { return try await refreshOpen(open, id: id) }
            catch { throw publicError(error) }
        }
        let stored: StoredSession
        do { stored = try loadStored(id) }
        catch { throw publicError(error) }

        let token = UUID()
        openingSessions.insert(id)
        let task = Task { [weak self] in
            guard let self else {
                throw HyperDRError(code: "internal_error", message: "Session store was released")
            }
            return try await self.activate(stored, id: id, token: token)
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

    private func awaitActivation(id: SessionID, flight: FlightState) async throws -> PhotoSession {
        let waiter = UUID()
        flight.waiters[waiter] = false
        defer { releaseActivationWaiter(id: id, flight: flight, waiter: waiter) }
        let session = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { await self.cancelActivationWaiter(id: id, flight: flight, waiter: waiter) }
        }
        try Task.checkCancellation()
        guard activating[id]?.token == flight.token else { throw CancellationError() }
        flight.claimed = true
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
            if !flight.claimed, let open = openSessions[id], open.generation == flight.token {
                openSessions.removeValue(forKey: id)
                open.lease.stop()
            }
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
        for directory in directories {
            let id = SessionID(rawValue: directory.lastPathComponent)
            if id.isValid, exporting[id] == nil, !openingSessions.contains(id), activating[id] == nil {
                cleanupAbandonedExports(id)
            }
        }
        _ = trimExportHistory()
        var removed = 0
        for directory in directories {
            let id = SessionID(rawValue: directory.lastPathComponent)
            guard id.isValid, openSessions[id] == nil, activating[id] == nil,
                  !openingSessions.contains(id), exporting[id] == nil else { continue }
            guard let stored = try? loadStored(id) else { continue }
            guard !openingPaths.contains(stored.sourcePath) else { continue }
            cleanupAbandonedExports(id)
            guard !hasPendingExport(id) else { continue }
            guard loadExportRecords(id).isEmpty, stored.lastUsedAt < cutoff else { continue }
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

    /// Keep the granted bookmark URL alive independently of an editor close.
    func exportSource(_ id: SessionID) async throws -> (PhotoSession, SecurityScopeLease) {
        let photo = try await session(id)
        guard let open = openSessions[id] else {
            throw HyperDRError(code: "session_expired", message: "Session closed during export preparation")
        }
        return (photo, SecurityScopeLease(url: open.lease.url, access: access))
    }

    private func releaseExport(_ id: SessionID, export: ExportID) {
        exporting[id]?.remove(export)
        if exporting[id]?.isEmpty == true { exporting.removeValue(forKey: id) }
    }

    public func prepareExport(_ id: SessionID, options: [String: JSONValue],
                              frame: ExportFrameRecord? = nil, key: ExportKey) async throws -> (id: ExportID, directory: URL) {
        let exportID = newExportID()
        // Reserve before session lookup suspends: cleanup must not remove the
        // workspace while a source refresh is hashing it.
        exporting[id, default: []].insert(exportID)
        do {
            let session = try await self.session(id)
            let folder = try exportDirectory(id, export: exportID)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let pending = PendingExport(id: exportID, options: options, sourceDigest: session.sha256, frame: frame, key: key)
            do {
                try write(pending, to: folder.appendingPathComponent("pending.json"))
                return (exportID, folder)
            } catch {
                try? removeExportDirectory(id, export: exportID)
                throw error
            }
        } catch {
            releaseExport(id, export: exportID)
            throw publicError(error)
        }
    }

    public func publishExport(_ id: SessionID, export: ExportID,
                              report: ConvertReport) async throws -> ExportRecord {
        defer { releaseExport(id, export: export) }
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
                options: pending.options, reportJSON: report.json,
                sequence: (loadExportRecords(id).map(\.sequence).max() ?? 0) + 1,
                key: pending.key, frame: pending.frame)
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
            releaseExport(id, export: export)
            _ = trimExportHistory()
            return record
        } catch {
            throw publicError(error)
        }
    }

    public func discardExport(_ id: SessionID, export: ExportID) async {
        defer { releaseExport(id, export: export) }
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

    /// Global published history, regardless of photo/source digest. Unpublished
    /// directories and active reservations never contribute to this budget.
    @discardableResult public func trimExportHistory() -> Int {
        guard let root = try? sessionsRoot(), let directories = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        var versions: [(SessionID, ExportRecord)] = []
        for directory in directories {
            let id = SessionID(rawValue: directory.lastPathComponent)
            guard id.isValid else { continue }
            for record in loadExportRecords(id) where exporting[id]?.contains(record.id) != true {
                versions.append((id, record))
            }
        }
        versions.sort {
            if $0.1.createdAt != $1.1.createdAt { return $0.1.createdAt > $1.1.createdAt }
            return $0.1.id.rawValue > $1.1.id.rawValue
        }
        var removed = 0
        for (session, record) in versions.dropFirst(exportHistoryLimit) {
            do { try removeExportDirectory(session, export: record.id); removed += 1 }
            catch { continue }
        }
        return removed
    }

    public func markSaved(_ id: SessionID, export: ExportID, saved: SavedMark) throws {
        // A version can be trimmed while its already-open file is copied.
        // Do not recreate its directory or fail a completed save in that case.
        guard loadExportRecords(id).contains(where: { $0.id == export }) else { return }
        let directory = try openExportDirectoryFD(id, export: export)
        defer { Darwin.close(directory) }
        try writeAtomically(try encoder.encode(saved), named: "saved.json", in: directory)
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

    func exportFile(_ id: SessionID, export: ExportID) async throws -> SessionExportFile {
        let records = await exports(for: id)
        guard let record = records.first(where: { $0.id == export }), isSafeComponent(record.name),
              !record.name.contains("\\"), let exportRoot else {
            throw HyperDRError(code: "source_missing", message: "The exported file is missing")
        }
        // Start with the root held since store creation. Every descendant is
        // opened separately with O_NOFOLLOW; no absolute path reopen follows
        // a concurrently replaced session/export ancestor.
        let directory = try openExportDirectoryFD(id, export: export, rootDescriptor: exportRoot.descriptor)
        defer { Darwin.close(directory) }
        let file = openExportLeaf(directory, record.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw HyperDRError(code: "source_missing", message: "The exported file is missing") }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0 else {
            Darwin.close(file)
            throw HyperDRError(code: "source_missing", message: "The export is not a regular file")
        }
        let flags = fcntl(file, F_GETFL)
        guard flags >= 0, fcntl(file, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            Darwin.close(file)
            throw HyperDRError(code: "source_missing", message: "Unable to read export")
        }
        return SessionExportFile(descriptor: file, name: record.name)
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

    /// K4: immutable LUT copies are installed through the pinned session root,
    /// without reopening an absolute resource path after an actor suspension.
    func lutDirectory(_ id: SessionID) throws -> SessionExportFile {
        guard id.isValid, let exportRoot else {
            throw HyperDRError(code: "session_expired", message: "The session is unavailable")
        }
        guard let session = try? openDirectory(named: id.rawValue, in: exportRoot.descriptor) else {
            throw HyperDRError(code: "session_expired", message: "The session is unavailable")
        }
        defer { Darwin.close(session) }
        try requireTrustedDevice(session)
        guard readFile(named: "session.json", in: session) != nil else {
            throw HyperDRError(code: "session_expired", message: "The session is unavailable")
        }
        guard mkdirat(session, "luts", 0o700) == 0 || errno == EEXIST else { throw posixError("mkdirat", "luts") }
        let directory = try openDirectory(named: "luts", in: session)
        do { try requireTrustedDevice(directory) }
        catch { Darwin.close(directory); throw error }
        return SessionExportFile(descriptor: directory, name: "")
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

    /// fstat of the opened leaf: no FIFO wait (O_NONBLOCK), no symlink leaf.
    private func fileFacts(_ url: URL) throws -> SourceFacts {
        let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw HyperDRError(code: "source_unreadable",
                message: "Unable to inspect \(url.lastPathComponent): \(reason)")
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let reason = String(cString: strerror(errno))
            throw HyperDRError(code: "source_unreadable",
                message: "Unable to inspect \(url.lastPathComponent): \(reason)")
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw HyperDRError(code: "source_unreadable", message: "The source is not a regular file")
        }
        guard info.st_size > 0 else {
            throw HyperDRError(code: "file_empty", message: "The source file is empty")
        }
        func nanoseconds(_ time: timespec) -> Int64 { Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec) }
        return SourceFacts(size: Int64(info.st_size), modifiedAt: nanoseconds(info.st_mtimespec),
                           changedAt: nanoseconds(info.st_ctimespec),
                           device: Int64(info.st_dev), inode: UInt64(info.st_ino))
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

    private func openExportDirectoryFD(_ id: SessionID, export: ExportID, rootDescriptor: Int32? = nil) throws -> Int32 {
        guard id.isValid, export.isValid else {
            throw HyperDRError(code: "invalid_options", message: "Invalid session or export id")
        }
        let root = try rootDescriptor.map { descriptor in
            let copy = dup(descriptor)
            guard copy >= 0 else { throw posixError("dup", "sessions") }
            return copy
        } ?? openDirectory(sessionsDirectory)
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
            let facts = try fileFacts(source)
            var stored = initial
            if stored.facts != facts || stored.sha256.isEmpty {
                let digest = try await digest(for: source, facts: facts)
                guard activating[id]?.token == token, !Task.isCancelled else {
                    throw CancellationError()
                }
                stored.sha256 = digest
                stored.record(facts)
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
                modifiedAt: stored.modifiedAt, generation: token, lastPersistedAt: Date())
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
        let facts = try fileFacts(open.url)
        var stored = try loadStored(id)
        guard openSessions[id]?.generation == generation, !Task.isCancelled else {
            throw CancellationError()
        }
        var sourceChanged = false
        if stored.facts != facts || stored.sha256.isEmpty {
            let digest = try await digest(for: open.url, facts: facts)
            guard openSessions[id]?.generation == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            sourceChanged = true
            stored.sha256 = digest
            stored.record(facts)
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
        let facts = try fileFacts(source)
        if stored.facts == facts && !stored.sha256.isEmpty {
            if stale {
                var refreshed = stored
                refreshed.sourceBookmark = try makeBookmark(url)
                try save(refreshed)
            }
            return stored.sha256
        }
        let digest = try await digest(for: source, facts: facts)
        var updated = stored
        updated.sha256 = digest
        updated.record(facts)
        updated.sourcePath = source.path
        if stale { updated.sourceBookmark = try makeBookmark(url) }
        try save(updated)
        return digest
    }

    private func digest(for url: URL, facts: SourceFacts) async throws -> String {
        if let cached = digestCache[url.path], cached.facts == facts {
            return cached.digest
        }
        digestComputations += 1
        let digest = try await sha256(url)
        digestCache[url.path] = CachedDigest(facts: facts, digest: digest)
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
                  (stored.lastUsedAt >= cutoff || !loadExportRecords(id).isEmpty) else { continue }
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
            guard var record = try? read(ExportRecord.self, from: folder.appendingPathComponent("result.json")) else {
                if fileManager.fileExists(atPath: folder.appendingPathComponent("result.json").path) {
                    Logger(subsystem: "com.hyperdr.HyperDR", category: "Session").debug("Discarding incompatible export record")
                }
                continue
            }
            guard record.id.rawValue == folder.lastPathComponent,
                  resultFileURL(id, record: record) != nil else { continue }
            record.saved = try? read(SavedMark.self, from: folder.appendingPathComponent("saved.json"))
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

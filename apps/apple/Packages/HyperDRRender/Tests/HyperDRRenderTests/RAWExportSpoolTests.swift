import Darwin
import Foundation
import Testing
@testable import HyperDRRender

// File-only tests: these do not open RAWs or touch a Metal device.
@Suite(.serialized) struct RAWExportSpoolTests {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spool-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fill(_ spool: RAWExportSpool, values: [Float]) throws {
        for y in stride(from: 0, to: spool.size.height, by: spool.cellSize.height) {
            for x in stride(from: 0, to: spool.size.width, by: spool.cellSize.width) {
                let w = min(spool.cellSize.width, spool.size.width - x)
                let h = min(spool.cellSize.height, spool.size.height - y)
                var tile: [Float] = []
                for row in y..<(y+h) {
                    let at = (row * spool.size.width + x) * 4
                    tile.append(contentsOf: values[at..<(at+w*4)])
                }
                try spool.append(tile, region: CGRect(x: x, y: y, width: w, height: h))
            }
        }
        try spool.seal()
    }

    @Test func bitExactAcrossCellEdgesAndArbitraryReplay() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let spool = try RAWExportSpool(size: .init(width: 7, height: 5), cellSize: .init(width: 3, height: 2),
            maximumBytes: 4096, reserveBytes: 0, directory: folder)
        // Storage never quantizes or interprets the samples. Include signed
        // zero, subnormal, signed wide gamut, >half-float and a NaN payload.
        let words: [UInt32] = [0, 0x80000000, 1, 0xbf000000, 0x47800000, 0x7fc00017, 0x3f800000]
        let values = (0..<(7*5*4)).map { Float(bitPattern: words[$0 % words.count]) }
        try fill(spool, values: values)
        for rect in [CGRect(x: 2, y: 1, width: 4, height: 3), CGRect(x: 6, y: 4, width: 1, height: 1),
                     CGRect(x: 0, y: 0, width: 7, height: 5), CGRect(x: 2, y: 1, width: 4, height: 3)] {
            let actual = try spool.read(region: rect).map(\.bitPattern)
            var expected: [UInt32] = []
            for y in Int(rect.minY)..<Int(rect.maxY) {
                let at = (y * 7 + Int(rect.minX)) * 4
                expected.append(contentsOf: values[at..<(at + Int(rect.width)*4)].map(\.bitPattern))
            }
            #expect(actual == expected)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func incompleteDuplicateAndOutOfOrderWritesAreNotPublished() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let spool = try RAWExportSpool(size: .init(width: 4, height: 2), cellSize: .init(width: 2, height: 2),
            maximumBytes: 4096, reserveBytes: 0, directory: folder)
        let left = CGRect(x: 0, y: 0, width: 2, height: 2), right = CGRect(x: 2, y: 0, width: 2, height: 2)
        let values = [Float](repeating: 1, count: 16)
        #expect(throws: ExportSpoolError.notSealed) { try spool.read(region: left) }
        #expect(throws: ExportSpoolError.incomplete) { try spool.seal() }
        #expect(throws: ExportSpoolError.invalidWriteOrder) { try spool.append(values, region: right) }
        try spool.append(values, region: left)
        #expect(throws: ExportSpoolError.invalidWriteOrder) { try spool.append(values, region: left) }
        #expect(throws: ExportSpoolError.incomplete) { try spool.seal() }
        try spool.append(values, region: right)
        try spool.seal()
        #expect(throws: ExportSpoolError.alreadySealed) { try spool.append(values, region: left) }
        #expect(throws: ExportSpoolError.alreadySealed) { try spool.seal() }
    }

    @Test func diskAdmissionAndQuotaFailWithoutOrphanFiles() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        #expect(throws: ExportSpoolError.quotaExceeded(required: 128, limit: 127)) {
            try RAWExportSpool(size: .init(width: 4, height: 2), cellSize: .init(width: 2, height: 2),
                maximumBytes: 127, reserveBytes: 0, directory: folder)
        }
        #expect(throws: ExportSpoolError.self) {
            try RAWExportSpool(size: .init(width: 4, height: 2), cellSize: .init(width: 2, height: 2),
                maximumBytes: 128, reserveBytes: UInt64(Int64.max), directory: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func descriptorIsPrivateAndOwnerIsNotRetained() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        var spool: RAWExportSpool? = try RAWExportSpool(size: .init(width: 2, height: 2),
            cellSize: .init(width: 2, height: 2), maximumBytes: 64, reserveBytes: 0, directory: folder)
        let fd = try #require(spool).descriptor
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        weak let weakSpool = spool
        spool = nil
        #expect(weakSpool == nil)
        // Do not inspect the released fd: a framework/other suite may already
        // have reused its number. Deinit's close is synchronous and explicit.
    }

    @Test func aDamagedFileCannotReturnBlackPixelsForEOF() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let spool = try RAWExportSpool(size: .init(width: 2, height: 2), cellSize: .init(width: 2, height: 2),
            maximumBytes: 64, reserveBytes: 0, directory: folder)
        try fill(spool, values: [Float](repeating: 1, count: 16))
        // Fault injection without closing/reusing a descriptor still owned by
        // the spool. EOF must fail, not leak uninitialized array memory.
        #expect(ftruncate(spool.descriptor, 16) == 0)
        #expect(throws: POSIXError.self) { try spool.read(region: CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }

    @Test func oversizedReadCannotBypassTileMemoryBound() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let width = PreparedExportRows.maximumSourceTileSize.width + 1
        let spool = try RAWExportSpool(size: .init(width: width, height: 1), cellSize: .init(width: 2, height: 1),
            maximumBytes: width*16, reserveBytes: 0, directory: folder)
        #expect(throws: RenderError.self) {
            try spool.read(region: CGRect(x: 0, y: 0, width: width, height: 1))
        }
    }

    @Test func shortIOAndInterruptedSyscallsPreserveEveryBit() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let reads = Calls(), writes = Calls()
        let io = RAWExportSpool.IO(read: { fd, bytes, count, offset in
            if reads.next() == 1 { errno = EINTR; return -1 }
            return Darwin.pread(fd, bytes, min(count, 11), offset)
        }, write: { fd, bytes, count, offset in
            if writes.next() == 1 { errno = EINTR; return -1 }
            return Darwin.pwrite(fd, bytes, min(count, 7), offset)
        })
        let spool = try RAWExportSpool(size: .init(width: 4, height: 3), cellSize: .init(width: 2, height: 2),
            maximumBytes: 192, reserveBytes: 0, directory: folder, io: io)
        let values = (0..<48).map { Float(bitPattern: UInt32(0x3f000000 + $0)) }
        try fill(spool, values: values)
        #expect(try spool.read(region: CGRect(x: 0, y: 0, width: 4, height: 3)).map(\.bitPattern) == values.map(\.bitPattern))
    }

    @Test func diskFullAfterPartialWritePermanentlyFailsTheSpool() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let writes = Calls()
        let io = RAWExportSpool.IO(write: { fd, bytes, count, offset in
            if writes.next() == 1 { return Darwin.pwrite(fd, bytes, min(count, 7), offset) }
            errno = ENOSPC; return -1
        })
        let spool = try RAWExportSpool(size: .init(width: 2, height: 2), cellSize: .init(width: 2, height: 2),
            maximumBytes: 64, reserveBytes: 0, directory: folder, io: io)
        let region = CGRect(x: 0, y: 0, width: 2, height: 2)
        #expect(throws: POSIXError(.ENOSPC)) { try spool.append([Float](repeating: 1, count: 16), region: region) }
        #expect(throws: ExportSpoolError.failedWrite) { try spool.seal() }
        #expect(throws: ExportSpoolError.failedWrite) { try spool.append([Float](repeating: 1, count: 16), region: region) }
        #expect(throws: ExportSpoolError.notSealed) { try spool.read(region: region) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func cancellationDuringWriteCannotPublishAnIncompleteImage() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let io = RAWExportSpool.IO(write: { fd, bytes, count, offset in
            let result = Darwin.pwrite(fd, bytes, min(count, 7), offset)
            withUnsafeCurrentTask { $0?.cancel() }
            return result
        })
        let spool = try RAWExportSpool(size: .init(width: 2, height: 2), cellSize: .init(width: 2, height: 2),
            maximumBytes: 64, reserveBytes: 0, directory: folder, io: io)
        let job = Task { try spool.append([Float](repeating: 1, count: 16), region: CGRect(x: 0, y: 0, width: 2, height: 2)) }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(throws: ExportSpoolError.failedWrite) { try spool.seal() }
    }

    @Test func concurrentReplayDoesNotShareAFileCursor() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let spool = try RAWExportSpool(size: .init(width: 16, height: 8), cellSize: .init(width: 4, height: 3),
            maximumBytes: 2048, reserveBytes: 0, directory: folder)
        let values = (0..<512).map { Float($0) }
        try fill(spool, values: values)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let x = index % 13, y = index % 6
                    for _ in 0..<8 {
                        let actual = try spool.read(region: CGRect(x: x, y: y, width: 4, height: 3))
                        let expected = (y..<(y+3)).flatMap { row in Array(values[((row*16+x)*4)..<((row*16+x+4)*4)]) }
                        #expect(actual == expected)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func cancellationDoesNotCreateAnOrphan() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let job = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try RAWExportSpool(size: .init(width: 2, height: 2), cellSize: .init(width: 2, height: 2),
                maximumBytes: 64, reserveBytes: 0, directory: folder)
        }
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

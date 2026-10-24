import Darwin
import Foundation

/// A staging failure is distinct from a RAW decode failure. No file paths or
/// photograph names belong in these errors (the host may log their kind).
enum ExportSpoolError: Error, Equatable {
    case quotaExceeded(required: Int, limit: Int)
    case insufficientSpace(required: UInt64, available: UInt64)
    case invalidWriteOrder
    case incomplete
    case notSealed
    case alreadySealed
    case failedWrite
}

/// Anonymous, uncached float32 RGBA storage in top-down native coordinates.
/// The producer supplies the canonical cell size; this class never develops
/// pixels or changes RAW rectangles. Cells must be appended once, row-major,
/// then sealed. Readers cannot observe a sparse/partially developed image.
///
/// Storage is physically reserved before development, not merely ftruncated.
/// Construct ALL endpoint spools before opening the first RAW graph, so a
/// second endpoint cannot discover insufficient space after costly development.
/// iOS integration must declare the disk-space required-reason API before use.
final class RAWExportSpool: @unchecked Sendable {
    /// Internal syscall seams for deterministic short-I/O/ENOSPC tests. The
    /// production default always performs real positioned I/O on this file.
    struct IO: Sendable {
        var read: @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { Darwin.pread($0, $1, $2, $3) }
        var write: @Sendable (Int32, UnsafeRawPointer, Int, off_t) -> Int = { Darwin.pwrite($0, $1, $2, $3) }
        static let system = IO()
    }

    let size: PixelSize
    let cellSize: PixelSize
    let byteCount: Int
    // Internal for descriptor-lifetime/fault tests; never exposed to app views.
    let descriptor: Int32
    static let bytesPerPixel = 4 * MemoryLayout<Float>.stride
    private let columns: Int
    private let cellCount: Int
    private let io: IO
    private let lock = NSLock()
    // All mutations hold lock. Once sealed, the descriptor is read-only in
    // practice and independent readers use pread without a shared file cursor.
    private var nextCell = 0
    private var sealed = false
    private var failed = false

    init(size: PixelSize, cellSize: PixelSize,
         maximumBytes: Int = 4 << 30, reserveBytes: UInt64 = 256 << 20,
         directory: URL = FileManager.default.temporaryDirectory, io: IO = .system) throws {
        let limit = PreparedExportRows.maximumSourceTileSize
        guard size.width > 0, size.height > 0,
              size.width <= Int(UInt32.max), size.height <= Int(UInt32.max),
              size.width <= Int.max / Self.bytesPerPixel / size.height,
              cellSize.width > 0, cellSize.height > 0,
              cellSize.width <= limit.width, cellSize.height <= limit.height else {
            throw RenderError.invalidSize
        }
        let bytes = size.width * size.height * Self.bytesPerPixel
        guard maximumBytes > 0, bytes <= maximumBytes else {
            throw ExportSpoolError.quotaExceeded(required: bytes, limit: maximumBytes)
        }
        let required = UInt64(bytes).addingReportingOverflow(reserveBytes)
        guard !required.overflow else { throw RenderError.invalidSize }
        try Task.checkCancellation()
        let fd = try Self.createAnonymousFile(directory: directory)
        var adopted = false
        defer { if !adopted { close(fd) } }
        guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw Self.ioError() }
        var filesystem = statfs()
        guard fstatfs(fd, &filesystem) == 0 else { throw Self.ioError() }
        guard filesystem.f_bsize > 0 else { throw POSIXError(.EIO) }
        let available = UInt64(filesystem.f_bavail).multipliedReportingOverflow(by: UInt64(filesystem.f_bsize))
        guard !available.overflow else { throw RenderError.invalidSize }
        guard available.partialValue >= required.partialValue else {
            throw ExportSpoolError.insufficientSpace(required: required.partialValue, available: available.partialValue)
        }
        // F_ALLOCATEALL allows fragmentation but requires every requested byte.
        // A failed/unsupported reservation is not a successful disk preflight.
        var reservation = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0, fst_length: off_t(bytes), fst_bytesalloc: 0)
        guard fcntl(fd, F_PREALLOCATE, &reservation) == 0 else { throw Self.ioError() }
        guard ftruncate(fd, off_t(bytes)) == 0 else { throw Self.ioError() }
        try Task.checkCancellation()
        self.size = size
        self.cellSize = cellSize
        byteCount = bytes
        descriptor = fd
        self.io = io
        let columnCount = (size.width - 1) / cellSize.width + 1
        columns = columnCount
        cellCount = columnCount * ((size.height - 1) / cellSize.height + 1)
        adopted = true
    }

    deinit { close(descriptor) }

    private static func ioError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static func createAnonymousFile(directory: URL) throws -> Int32 {
        for _ in 0..<8 {
            try Task.checkCancellation()
            let path = directory.appendingPathComponent("hyperdr-raw-\(UUID().uuidString)").path
            // CLOEXEC is atomic with creation: setting it after mkstemp leaves
            // a window for another thread's fork/exec to inherit photo data.
            let fd = path.withCString {
                Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            }
            if fd < 0 {
                if errno == EEXIST { continue }
                throw ioError()
            }
            // Never write photograph pixels unless deletion succeeded. Closing
            // the last descriptor on failure/exit frees its disk allocation.
            guard path.withCString({ unlink($0) }) == 0 else {
                let error = ioError(); close(fd); throw error
            }
            return fd
        }
        throw POSIXError(.EEXIST)
    }

    private func dimensions(_ region: CGRect) throws -> (x: Int, y: Int, width: Int, height: Int) {
        guard !region.isNull, region.origin.x.isFinite, region.origin.y.isFinite,
              region.width.isFinite, region.height.isFinite, region == region.integral,
              region.minX >= 0, region.minY >= 0, region.width > 0, region.height > 0,
              region.maxX <= Double(size.width), region.maxY <= Double(size.height) else {
            throw RenderError.invalidRegion
        }
        return (Int(region.minX), Int(region.minY), Int(region.width), Int(region.height))
    }

    /// Only canonical INNER pixels, in top-down order; halo pixels are read
    /// later from neighboring stored cells, never redeveloped at a new shape.
    func append(_ pixels: [Float], region: CGRect) throws {
        try Task.checkCancellation()
        let r = try dimensions(region)
        try lock.withLock {
            guard !failed else { throw ExportSpoolError.failedWrite }
            guard !sealed else { throw ExportSpoolError.alreadySealed }
            guard nextCell < cellCount else { throw ExportSpoolError.invalidWriteOrder }
            let x = nextCell % columns * cellSize.width, y = nextCell / columns * cellSize.height
            let expected = CGRect(x: x, y: y, width: min(cellSize.width, size.width - x),
                                  height: min(cellSize.height, size.height - y))
            guard region == expected else { throw ExportSpoolError.invalidWriteOrder }
            guard pixels.count == r.width * r.height * 4 else { throw RenderError.invalidSize }
            do {
                try pixels.withUnsafeBytes { bytes in
                    for row in 0..<r.height {
                        try transfer(bytes.baseAddress! + row * r.width * Self.bytesPerPixel,
                            count: r.width * Self.bytesPerPixel,
                            offset: ((r.y + row) * size.width + r.x) * Self.bytesPerPixel, writing: true)
                    }
                }
                nextCell += 1
            } catch {
                // An interrupted/partial write must never be resumed into a
                // seemingly complete image. Its owner closes the entire spool.
                failed = true
                throw error
            }
        }
    }

    func seal() throws {
        try Task.checkCancellation()
        try lock.withLock {
            guard !failed else { throw ExportSpoolError.failedWrite }
            guard !sealed else { throw ExportSpoolError.alreadySealed }
            guard nextCell == cellCount else { throw ExportSpoolError.incomplete }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw Self.ioError() }
            guard info.st_size == off_t(byteCount) else { throw ExportSpoolError.incomplete }
            sealed = true
        }
    }

    /// Arbitrary, replayable ROI including cross-cell sampling/film halos.
    /// Never permits a whole-image read to bypass the Render tile envelope.
    func read(region: CGRect) throws -> [Float] {
        try Task.checkCancellation()
        let r = try dimensions(region)
        let limit = PreparedExportRows.maximumSourceTileSize
        guard r.width <= limit.width, r.height <= limit.height else { throw RenderError.invalidRegion }
        try lock.withLock {
            guard sealed else { throw ExportSpoolError.notSealed }
        }
        return try [Float](unsafeUninitializedCapacity: r.width * r.height * 4) { pixels, initialized in
            for row in 0..<r.height {
                try transfer(UnsafeRawPointer(pixels.baseAddress! + row * r.width * 4),
                    count: r.width * Self.bytesPerPixel,
                    offset: ((r.y + row) * size.width + r.x) * Self.bytesPerPixel, writing: false)
            }
            initialized = pixels.count
        }
    }

    private func transfer(_ bytes: UnsafeRawPointer, count: Int, offset: Int, writing: Bool) throws {
        var done = 0
        while done < count {
            try Task.checkCancellation()
            let n = writing
                ? io.write(descriptor, bytes + done, count - done, off_t(offset + done))
                : io.read(descriptor, UnsafeMutableRawPointer(mutating: bytes + done), count - done, off_t(offset + done))
            if n < 0 {
                if errno == EINTR { continue }
                throw Self.ioError()
            }
            // EOF is not a valid black tile. It indicates a damaged spool.
            guard n > 0 else { throw POSIXError(.EIO) }
            done += n
        }
    }
}

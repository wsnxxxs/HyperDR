#if os(iOS)
import Darwin // os_proc_available_memory
#endif
import Foundation

/// Peak footprint of each successive stage, not the sum of all stages
/// (`modules/app/include/hyperdr/app/export_memory.hpp`, E6).
public struct ExportMemoryEstimate: Sendable, Hashable {
    public let decode: Int
    public let render: Int
    public let composite: Int
    public let packaging: Int
    public let encode: Int
    public let verify: Int

    public init(decode: Int, render: Int, composite: Int, packaging: Int, encode: Int, verify: Int) {
        self.decode = decode
        self.render = render
        self.composite = composite
        self.packaging = packaging
        self.encode = encode
        self.verify = verify
    }

    public var peak: Int {
        max(max(max(decode, render), max(composite, packaging)), max(encode, verify))
    }

    public func fits(in availableBytes: Int) -> Bool { peak <= availableBytes }
}

/// What the export may use on this host. Injected so a test can state the
/// budget instead of borrowing the machine's.
public protocol ExportMemoryBudget: Sendable {
    /// Bytes available to the export now, or nil when the host cannot say
    /// (admission is then skipped rather than guessed).
    func availableBytes() -> Int?
}

/// The device's own answer: `os_proc_available_memory` on iOS/iPadOS, a
/// conservative share of physical memory on the Mac.
public struct SystemExportMemoryBudget: ExportMemoryBudget {
    /// macOS keeps no per-process limit we can read, and the app shares the
    /// machine with everything else, so admission uses a share of RAM. iOS is
    /// asked directly; only when it declines does the share stand in. P7-3
    /// re-measures admission against the new pipeline, so the share is a value.
    public let physicalShare: Double

    public init(physicalShare: Double = 0.5) { self.physicalShare = physicalShare }

    public func availableBytes() -> Int? {
        #if os(iOS)
        let reported = Int(os_proc_available_memory())
        if reported > 0 { return reported }
        #endif
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0, physicalShare > 0 else { return nil }
        return Int(Double(physical) * physicalShare)
    }
}

/// A fixed budget for tests and for a caller that measures its own.
public struct FixedExportMemoryBudget: ExportMemoryBudget {
    public let bytes: Int?
    public init(bytes: Int?) { self.bytes = bytes }
    public func availableBytes() -> Int? { bytes }
}

/// What admission did when the estimate did not fit.
public enum ExportDegradation: Sendable, Hashable {
    /// The preferred writer did not fit; this writer's lower peak does.
    case switchedWriter(ExportWriter)
    /// The canvas is written in strips of `rowHeight` rows.
    case strips(rowHeight: Int)
    /// Nothing fit: the plan is refused and a blocker says why.
    case refused
}

/// The memory part of a plan.
public struct ExportMemoryPlan: Sendable, Hashable {
    /// The estimate for what the plan will actually do (after any degradation).
    public let estimate: ExportMemoryEstimate
    /// nil when the host could not report what is free.
    public let availableBytes: Int?
    public let degradation: ExportDegradation?

    public init(estimate: ExportMemoryEstimate, availableBytes: Int?, degradation: ExportDegradation?) {
        self.estimate = estimate
        self.availableBytes = availableBytes
        self.degradation = degradation
    }

    public var fits: Bool {
        guard let availableBytes else { return true }
        return estimate.fits(in: availableBytes)
    }
}

/// The bytes an export keeps alive beside the pixels: the LUT snapshot and the
/// frame's specification and caption overlay, summed the way E6's
/// `export_resource_bytes` does. An external gain grid is not here: the P7
/// pipeline's source node is ImageIO or CIRAWFilter only (gpu-pipeline §4), so a
/// sidecar grid is not an input to this export.
public struct ExportRetainedResources: Sendable, Hashable {
    public var lutAssetBytes: Int
    public var lutValueCount: Int
    public var frameSpecificationBytes: Int
    public var frameOverlayBytes: Int
    public var frameOverlayPixels: Int

    public init(lutAssetBytes: Int = 0, lutValueCount: Int = 0,
                frameSpecificationBytes: Int = 0, frameOverlayBytes: Int = 0,
                frameOverlayPixels: Int = 0) {
        self.lutAssetBytes = lutAssetBytes
        self.lutValueCount = lutValueCount
        self.frameSpecificationBytes = frameSpecificationBytes
        self.frameOverlayBytes = frameOverlayBytes
        self.frameOverlayPixels = frameOverlayPixels
    }

    /// A LUT value is an `array<float, 3>`; the overlay is kept as RGBA float.
    public var bytes: Int {
        lutAssetBytes + lutValueCount * 12 + frameSpecificationBytes
            + frameOverlayBytes + frameOverlayPixels * 16
    }
}

extension ExportMemoryEstimate {
    /// Rows written at once when a writer streams a canvas. E6's HEVC tile
    /// height, so a strip costs the buffers the encoder already holds.
    public static let stripHeight = 512

    struct Input {
        let source: ExportSource
        /// The photo as it is graded and written: the source limited to the
        /// destination's long edge.
        let photoSize: ExportPixelSize
        /// What is written: `photoSize`, or a frame's canvas around it.
        let canvas: ExportPixelSize
        let encoding: ExportEncoding
        let writer: ExportWriter
        let writesGainMap: Bool
        let isFramed: Bool
        let baseBitDepth: Int
        /// Rows of the canvas encoded at once: the canvas height, or a strip's.
        let writeRows: Int
        let retainedBytes: Int
    }

    /// E6's model, kept in the same shape: the stages of one export, each with
    /// the footprints E6 measured, the ImageIO 8-bit HEIC pair added from
    /// writer-lab (3.11 GiB at 61 MP against 1.21 GiB for ours), and the
    /// canvas-sized terms of packaging, encoding and verification bounded by
    /// `writeRows` so a streaming writer can be asked what a strip would cost.
    static func estimate(_ input: Input) -> ExportMemoryEstimate {
        let mib = 1024 * 1024
        // Decoding works on the source's own raster; grading and writing work on
        // the size the destination asks for.
        let source = input.source.pixelSize
        let photo = input.photoSize
        let photoPixels = photo.pixels
        let canvasPixels = input.canvas.pixels
        let writeRows = min(max(input.writeRows, 1), input.canvas.height)
        let writePixels = input.canvas.width * writeRows
        let sensorPixels = (input.source.sensorSize ?? source).pixels

        let sdr = input.encoding.isSDR
        let raw = input.source.kind == .raw
        // An imported pair holds its HDR and SDR float planes beside the gain
        // map; a single-rendition raster does not.
        let pair = input.source.kind == .dual
        let raster = input.source.kind == .raster
        // RAW keeps the renderer's floor plus a GPU working set; everything
        // else pays the process and framework caches.
        let overhead = raw ? 192 * mib : 32 * mib
        let resident = raw ? sensorPixels * 16 : 0
        let main10 = input.baseBitDepth == 10
        // Four 512-row tiles in flight, whatever the thread count, and the
        // VideoToolbox floor.
        let tileWorkingSet = 4 * 512 * 512 * (main10 ? 3 : 2) + 32 * mib

        let decode = raw
            ? overhead + resident + source.pixels * 12 + source.width * 512 * 16
            : overhead + source.pixels * (pair ? 40 : 15)
        let renderPlanes = pair ? (sdr ? 48 : 64)
            : raster ? (sdr ? 27 : 48)
            : (sdr ? 24 : 44)
        let render = overhead + resident + photoPixels * renderPlanes
        let composite = input.isFramed
            ? overhead + resident + photoPixels * (sdr ? 12 : 24) + canvasPixels * (raster ? 16 : 13)
            : 0
        // Only a pair is repackaged; a base written straight out does not.
        let packaging: Int
        if input.writesGainMap {
            packaging = input.encoding == .isoGainMapJPEG
                ? overhead + resident + photoPixels * (raster ? 24 : 3) + writePixels * (raster ? 24 : 25)
                : overhead + resident + photoPixels * (raster ? 24 : 12) + writePixels * 21
        } else {
            packaging = 0
        }

        let avifCell = input.encoding.isAVIF ? Self.avifCell(canvas: input.canvas) : nil
        let encode: Int
        let verify: Int
        switch input.encoding {
        case .isoGainMapJPEG:
            encode = overhead + resident + writePixels * 27
            verify = overhead + resident + writePixels * 16
        case .adaptive:
            if input.writer == .imageIO {
                // writer-lab's B path holds the whole canvas as ImageIO buffers on
                // top of ours and cannot stream; a plain 8-bit SDR HEIC (no pair
                // to carry) costs the single-rendition path instead.
                encode = overhead + resident + canvasPixels * (input.writesGainMap ? 53 : 20)
            } else {
                encode = overhead + resident + writePixels * 20 + tileWorkingSet
            }
            verify = overhead + resident + writePixels * 4
        case .pq, .hlg:
            encode = overhead + resident + writePixels * 16 + tileWorkingSet
            verify = overhead + resident + writePixels * 4
        case .avifPq, .avifHlg:
            if let avifCell {
                // A grid converts and codes one cell at a time; the finished
                // YUV cells stay beside the canvas.
                encode = overhead + resident + canvasPixels * 18 + avifCell.pixels * 42
                    + photoPixels * (raster ? 24 : 0)
                verify = overhead + resident + canvasPixels * 18 + avifCell.pixels * 20
            } else {
                encode = overhead + resident + canvasPixels * ((!raw && !input.isFramed) ? 78 : 66)
                verify = overhead + resident + canvasPixels * 20
            }
        case .sdrJPEG, .sdrTIFF:
            encode = overhead + resident + writePixels * 20
            verify = overhead + resident + writePixels * 16
        }

        return ExportMemoryEstimate(
            decode: decode + input.retainedBytes,
            render: render + input.retainedBytes,
            composite: composite + input.retainedBytes,
            packaging: packaging + input.retainedBytes,
            encode: encode + input.retainedBytes,
            verify: verify + input.retainedBytes)
    }

    /// libaom refuses a source frame above its cap, so a large canvas is coded
    /// as a grid of cells (`modules/codec/include/hyperdr/codec/avif_grid.hpp`).
    /// nil means one item, which is what every destination size uses.
    static func avifCell(canvas: ExportPixelSize) -> ExportPixelSize? {
        let border = 160
        let alignedWidth = (canvas.width + 7) & ~7
        let alignedHeight = (canvas.height + 7) & ~7
        let stride = (alignedWidth + 2 * border + 31) & ~31
        let plane = (alignedHeight + 2 * border) * stride
        let pyramid = canvas.pixels / 3 * 4 + (1 << 20)
        let singleFrame = 2 * 3 * plane + pyramid
        guard singleFrame > avifSingleFrameBudget else { return nil }
        let maxCell = 4096, alignment = 64
        let columns = min(max((canvas.width + maxCell - 1) / maxCell, 1), 256)
        let rows = min(max((canvas.height + maxCell - 1) / maxCell, 1), 256)
        func cellSide(_ size: Int, _ count: Int) -> Int {
            guard count > 1 else { return size }
            let balanced = (size + count - 1) / count
            return (balanced + alignment - 1) / alignment * alignment
        }
        return ExportPixelSize(width: cellSide(canvas.width, columns),
                               height: cellSide(canvas.height, rows))
    }

    /// libaom's 1 GiB cap, less a tenth for allocator and build differences.
    static let avifSingleFrameBudget = (1 << 30) / 10 * 9
}

extension ExportEncoding {
    var isAVIF: Bool { self == .avifPq || self == .avifHlg }
}

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
    /// (admission then uses the explicit conservative 256 MiB limit).
    func availableBytes() -> Int?
}

/// The device's own answer: `os_proc_available_memory` on iOS/iPadOS, a
/// conservative share of physical memory on the Mac.
public struct SystemExportMemoryBudget: ExportMemoryBudget {
    /// macOS keeps no per-process limit we can read, and the app shares the
    /// machine with everything else, so admission uses a share of RAM. iOS is
    /// asked directly, reserving 20% of its reported available memory. A missing
    /// iOS measurement never falls back to a fraction of physical RAM.
    public let physicalShare: Double

    public init(physicalShare: Double = 0.5) { self.physicalShare = physicalShare }

    public func availableBytes() -> Int? {
        #if os(iOS)
        let reported = Int(os_proc_available_memory())
        if reported > 0 { return Int(Double(reported) * 0.8) }
        return nil
        #else
        let physical = Int(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0, physicalShare > 0 else { return nil }
        return Int(Double(physical) * physicalShare)
        #endif
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
    /// Only GPU/readback rows shrink. Full CPU planes and codec copies remain.
    case renderRows(rowHeight: Int)
    /// Nothing fit: the plan is refused and a blocker says why.
    case refused
}

/// The memory part of a plan.
public struct ExportMemoryPlan: Sendable, Hashable {
    /// The estimate for what the plan will actually do (after any degradation).
    public let estimate: ExportMemoryEstimate
    public let renderRows: Int
    /// The measured budget, or the explicit conservative limit.
    public let availableBytes: Int?
    public let degradation: ExportDegradation?

    public init(estimate: ExportMemoryEstimate, availableBytes: Int?, degradation: ExportDegradation?, renderRows: Int = 256) {
        self.renderRows = renderRows
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

    /// A LUT value costs three copies of 16 bytes: the CPU table
    /// (`[SIMD3<Float>]` has a 16-byte stride), the `rgba32Float` 3D texture, and
    /// the `[SIMD4<Float>]` the upload stages through (HyperDRRender's
    /// `ColorLUT`). The frame overlay is RGBA float.
    public var bytes: Int {
        lutAssetBytes + lutValueCount * (16 * 3) + frameSpecificationBytes
            + frameOverlayBytes + frameOverlayPixels * 16
    }
}

extension ExportMemoryEstimate {
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
        /// GPU stripe rows. Does not change CPU owners or writer allocations.
        let writeRows: Int
        let retainedBytes: Int
    }

    /// b-stage allocation model. Source, whole-plane owners, ABI copies and
    /// codec buffers overlap; rendering stripes never imply streaming encoding.
    static func estimate(_ input: Input) -> ExportMemoryEstimate {
        let sourcePixels = input.source.pixelSize.pixels
        let p = input.canvas.pixels
        // Reserve RGB gain even if analysis later produces mono. Full source,
        // CPU owner and package's copy_plane are real overlapping allocations.
        let needsGain = input.writesGainMap || input.encoding.isBT2100
        let pairBytes = needsGain ? 24 : 12
        let source = sourcePixels * (input.source.domain == .dual ? 48 : 16)
        let rawCache = input.source.domain == .rawEDR
            ? (input.source.sensorSize ?? input.source.pixelSize).pixels * 16 : 0
        let resident = source + rawCache + input.retainedBytes + 32 * 1024 * 1024
        let owner = p * pairBytes
        // GPU output remains alive while readback packs RGBA into RGB. RGB
        // gain peaks at (4+3 + 4+3) Floats = 56 CPU bytes per stripe pixel,
        // alongside two RGBA textures (32 GPU bytes) and the whole CPU owner.
        // Without gain, Render still allocates its single-channel gain texture.
        let stripeGPUBytes = needsGain ? 32 : 20
        let stripeCPUBytes = needsGain ? 56 : 28
        let stripe = input.canvas.width * min(input.writeRows, input.canvas.height)
            * (stripeGPUBytes + stripeCPUBytes)
        let render = resident + owner + stripe + input.photoSize.pixels * 64
        // Quantized planes, full-plane copies, HDR reconstruction and encoder
        // workspace. AVIF retains YUV cells and the canvas beside the codec.
        let codec = input.encoding.isAVIF ? p * 96
            : input.encoding == .adaptive || input.encoding.isBT2100 ? p * 32 + 48 * 1024 * 1024
            : p * 20
        // ImageIO receives explicit 8-bit RGBA (4 B/px) and up to RGB gain
        // (3 B/px), retaining their CGImage/auxiliary handoff copies. Reserve
        // HEVC/framework workspace separately; it never borrows Float owners.
        let imageIO = input.writer == .imageIO && input.writesGainMap && input.encoding == .adaptive
        let encode = imageIO
            ? resident + owner + p * (4 * 2 + 3 * 2 + 32) + 64 * 1024 * 1024
            : resident + owner * 2 + codec
        let verify = resident + owner + p * (needsGain ? 40 : 16)
        return .init(decode: resident, render: render, composite: render,
                     packaging: encode, encode: encode, verify: verify)
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

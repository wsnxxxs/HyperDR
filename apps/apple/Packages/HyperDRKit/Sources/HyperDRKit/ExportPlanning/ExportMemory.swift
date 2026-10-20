#if os(iOS)
import Darwin // os_proc_available_memory
#endif
import Foundation
import HyperDRRender

/// Peak footprint of each successive stage, not the sum of all stages
/// Row rendering follows HyperDRRender/EXPORT_MEMORY.md.
public struct ExportMemoryEstimate: Sendable, Hashable {
    public let decode: Int
    public let render: Int
    public let composite: Int
    public let packaging: Int
    public let encode: Int
    /// The independent native and system reader peaks; verify is their maximum.
    public let nativeVerify: Int
    public let systemVerify: Int
    public let verify: Int

    public init(decode: Int, render: Int, composite: Int, packaging: Int, encode: Int, verify: Int,
                nativeVerify: Int? = nil, systemVerify: Int? = nil) {
        self.decode = decode
        self.render = render
        self.composite = composite
        self.packaging = packaging
        self.encode = encode
        self.nativeVerify = nativeVerify ?? verify
        self.systemVerify = systemVerify ?? verify
        self.verify = max(self.nativeVerify, self.systemVerify)
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
/// conservative share of host physical memory on the Mac and iOS Simulator.
public struct SystemExportMemoryBudget: ExportMemoryBudget {
    /// macOS keeps no per-process limit we can read, and the app shares the
    /// machine with everything else, so admission uses a share of RAM. Physical
    /// iOS devices are asked directly, reserving 20% of reported available memory.
    /// A missing physical-device measurement never uses a fraction of RAM.
    /// Simulator memory belongs to the host Mac and does not predict device
    /// capacity: 110MP original-size export must be validated on a real device.
    public let physicalShare: Double

    public init(physicalShare: Double = 0.5) { self.physicalShare = physicalShare }

    public func availableBytes() -> Int? {
        #if os(iOS) && !targetEnvironment(simulator)
        let reported = Int(os_proc_available_memory())
        if reported > 0 { return Int(Double(reported) * 0.8) }
        return nil
        #else
        // os_proc_available_memory() returns zero on Simulator. Use the same
        // host policy as macOS; this budget says nothing about a real iPhone.
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
    /// Input/readback rows shrink. Whole-plane owners (when used), the fixed
    /// analysis scan, HEIC slab and system reader reservation do not.
    case renderRows(rowHeight: Int)
    /// Nothing fit: the plan is refused and a blocker says why.
    case refused
}

/// The memory part of a plan.
public struct ExportMemoryPlan: Sendable, Hashable {
    /// The estimate for what the plan will actually do (after any degradation).
    public let estimate: ExportMemoryEstimate
    public let renderRows: Int
    public let usesRowInput: Bool
    /// The measured budget, or the explicit conservative limit.
    public let availableBytes: Int?
    public let degradation: ExportDegradation?
    /// Largest admitted photo long edge under this budget; nil if none was found.
    /// Only computed after refusal. Rebuild the frame layout before applying it.
    public let maxAdmissibleLongEdge: Int?

    public init(estimate: ExportMemoryEstimate, availableBytes: Int?, degradation: ExportDegradation?, renderRows: Int = 256, usesRowInput: Bool = false, maxAdmissibleLongEdge: Int? = nil) {
        self.maxAdmissibleLongEdge = maxAdmissibleLongEdge
        self.renderRows = renderRows
        self.usesRowInput = usesRowInput
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
        /// Pull row height (clamped to Render's maximum); also sizes CPU row owners.
        let writeRows: Int
        let retainedBytes: Int
        var allowsRowInput: Bool = true
        var quality: Int = 90
        var gainChannels: Int = 3
    }

    /// b-stage allocation model. Source, whole-plane owners, ABI copies and
    /// codec buffers overlap; rendering stripes never imply streaming encoding.
    static func estimate(_ input: Input) -> ExportMemoryEstimate {
        if input.allowsRowInput && input.writer.supportsRowInput(encoding: input.encoding) {
            return estimateRows(input)
        }
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

    /// Lazy Render plus pull writer. Decoder/CIRAWFilter residency remains a
    /// reserve, never an inferred guarantee from the absence of a full texture.
    private static func estimateRows(_ input: Input) -> ExportMemoryEstimate {
        // Empirical allowance, NOT an Apple decoder cap: one native decode at
        // 24 B/pixel plus 512 MiB for bounded ROI graphs, packing scratch,
        // analysis and framework/cache variation. Do not charge retired full
        // Render source/output/composite textures, or scale tiles with canvas.
        let nativePixels = max(input.source.pixelSize.pixels,
            input.source.sensorSize?.pixels ?? 0)
        let decoder = nativePixels * 24
        // Until native auxiliary dimensions are available, reserve a full-size
        // RGBAf gain resource for dual input; it is separate from base decode.
        let auxiliary = input.source.domain == .dual ? input.source.pixelSize.pixels * 16 : 0
        let resident = decoder + 512 * 1024 * 1024 + auxiliary + input.retainedBytes
        let gain = input.writesGainMap || input.encoding.isBT2100
        let channels = gain ? input.gainChannels : 0
        let rows = min(input.writeRows, PreparedExportRows.maximumReadRows, input.canvas.height)
        // The returned Float arrays and native callback destination coexist.
        // Bounded tile packing scratch is covered by the fixed ROI allowance.
        let readback = 4 * (3 + channels) * input.canvas.width * rows
        let packageBand = readback
        // The empirical 512 MiB work allowance was measured for mono. RGB
        // packing raises the tile high-water from 28 to 40 B/pixel (contract).
        let rgbScratch = channels > 1 ? 12 * PreparedExportRows.maximumSourceTileSize.width
            * PreparedExportRows.maximumReadRows : 0
        let heic = input.encoding == .adaptive || input.encoding.isBT2100
        // encode_heic_rows materializes one RGB Float slab (12 B/px), not
        // full-width YUV/float canvases. VT has at most four 512px pictures in
        // flight; reserve their buffers/framework workspace separately (32 MiB).
        // The sink retains compressed tiles, but never a complete output container.
        let codec = heic ? input.canvas.width * min(512, input.canvas.height) * 12 + 32 * 1024 * 1024
            : input.canvas.width * 32
        let compressedCache = heic ? compressedHEICCache(pixels: input.canvas.pixels,
            bitDepth: input.baseBitDepth, quality: input.quality) : 0
        // Both package routes stream the container into the staged file.
        // Items and each <=256 KiB sink write borrow the sequence bytes; there
        // is no chunk allocation or complete output vector. Keep the existing
        // 32 MiB allowance for bounded metadata/box construction and filebuf;
        // encoding slabs/VT pictures have finished before assembly.
        let rowResident = resident + rgbScratch + readback + packageBand
        let encode = rowResident + codec + compressedCache
        let assembly = heic ? rowResident + 32 * 1024 * 1024 + compressedCache : encode
        let render = resident + rgbScratch
        // Native verification releases input bands first and scans rows, or
        // decodes one 512×512 HEIC tile pair with bounded VT pictures. Keep the
        // reader's last ROI/graph priced while it remains alive in the caller.
        let verifierResident = resident
        let nativeWorkspace = (heic ? 512 * 512 * 40 : input.canvas.width * 128) + 8 * 1024 * 1024
        let nativeVerify = verifierResident + nativeWorkspace
        // No full auxiliary dictionary on native row output. JPEG/HEIC CI
        // readback requests decoder subsampling by 8 and a <=256px thumbnail.
        // Keep decoder row/tile workspace beside fixed base/gain/float buffers.
        let systemVerify = verifierResident + nativeWorkspace + 256 * 256 * (gain ? 40 : 16)
        return .init(decode: resident, render: render, composite: render,
                     packaging: assembly, encode: encode, verify: max(nativeVerify, systemVerify),
                     nativeVerify: nativeVerify, systemVerify: systemVerify)
    }

    /// GPU-only bound for a row export; decoder CPU caches are priced above.
    /// Tile sizes and device limits belong to Render, never to Kit policy.
    static func rowGPUBytes(maximumTextureDimension: Int) -> Int {
        let source = PreparedExportRows.maximumSourceTileSize
        let width = min(source.width, maximumTextureDimension)
        let height = min(source.height, maximumTextureDimension)
        let outputRows = min(PreparedExportRows.maximumReadRows, maximumTextureDimension)
        return width * height * 48 + width * outputRows * 64 + 1024 * 1024 * 48
    }

    /// Upper envelope from 1MP random base + random gain native writer samples,
    /// not a fixed RGB byte count. Includes 20% rate variation and container slack
    /// for the single retained encoded sequence. The file sink and Item payloads
    /// borrow these samples without retaining an assembled container. Smooth RAW
    /// gain maps normally encode far below this envelope; do not assume that.
    static func compressedHEICCache(pixels: Int, bitDepth: Int, quality: Int) -> Int {
        let rates = bitDepth == 10 ? [20.533, 23.966, 25.671] : [17.405, 19.035, 19.640] // bits/pixel
        let q = min(100, max(90, quality))
        let index = q <= 95 ? 0 : 1
        let t = Double(q - (index == 0 ? 90 : 95)) / 5
        let bits = rates[index] + (rates[index+1] - rates[index]) * t
        let encoded = Int(ceil(Double(pixels) * bits * 1.2 / 8)) + 2 * 1024 * 1024
        return encoded
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

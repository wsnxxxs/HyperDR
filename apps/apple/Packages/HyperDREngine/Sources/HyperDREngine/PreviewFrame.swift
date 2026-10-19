import Foundation
import HyperDREngineCore
import Metal

public struct PreviewMetadata: Codable, Sendable {
    public struct Unadjusted: Codable, Sendable {
        public let brightness, hdrStrength, hdrRange, areaCoverage, lutStrength: Double
    }
    public let schema: String
    public let width, height, channels: Int
    public let layout, sampleType, colorSpace: String
    public let relativeSdrWhite, headroomStops: Double
    public let inputDomain, status: String
    public let raw: RawCapabilities?
    public let sourceColor: SourceColor
    public let degradationReasons: [String]
    public let unadjusted: Unadjusted
    public let hasCaptureMetadata: Bool
    public let inputHeadroomStops: Double
    public let inputContentPeakNits: Double?
    public let sourceWidth, sourceHeight: Int?
    /// log2 stops, not linear headroom multiples (v2 only).
    public let baseHeadroom, alternateHeadroom: Double?
    public let gainWidth, gainHeight: Int?
    public let gainMin, gainMax, gainGamma, gainWeight, baseOffset, alternateOffset: Double?
    public let baseId: String?
    public let detail: Bool?
    public let fullWidth, fullHeight, regionX, regionY: Int?
}

public enum PlaneFormat: Sendable { case float32 }

/// Immutable native storage. FramePlane retains this as well, so a plane remains
/// valid even when its originating PreviewFrame has been released.
final class FrameStorage: @unchecked Sendable {
    private var frame: hyperdr_frame
    init(_ frame: hyperdr_frame) { self.frame = frame }
    var value: hyperdr_frame { frame }
    deinit { hyperdr_frame_free(&frame) }
}

public struct FramePlane: Sendable {
    public let width, height, channels, rowBytes, allocationBytes: Int
    public let format: PlaneFormat
    private let storage: FrameStorage
    private let isBase: Bool
    private var plane: hyperdr_plane { isBase ? storage.value.base : storage.value.gain }
    init(storage: FrameStorage, isBase: Bool) throws {
        let plane = isBase ? storage.value.base : storage.value.gain
        guard plane.format == HYPERDR_PLANE_F32 else {
            throw HyperDRError(code: "unsupported", message: "Unsupported frame plane format: \(plane.format)")
        }
        guard plane.data != nil, plane.width > 0, plane.height > 0,
              plane.row_bytes >= Int(plane.width) * Int(plane.channels) * MemoryLayout<Float>.size,
              plane.size >= plane.row_bytes * Int(plane.height) else {
            throw HyperDRError(code: "internal_error", message: "Invalid engine frame plane")
        }
        self.storage = storage; self.isBase = isBase
        width = Int(plane.width); height = Int(plane.height); channels = Int(plane.channels)
        rowBytes = plane.row_bytes; allocationBytes = plane.size; format = .float32
    }
    /// Exposes tightly packed pixel bytes, excluding page allocation padding.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try withExtendedLifetime(storage) {
            try body(UnsafeRawBufferPointer(start: plane.data, count: rowBytes * height))
        }
    }
    fileprivate func metalBuffer(device: any MTLDevice) throws -> any MTLBuffer {
        let storage = self.storage
        guard let buffer = device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: plane.data!),
            length: allocationBytes, options: .storageModeShared,
            deallocator: { _, _ in withExtendedLifetime(storage) {} }) else {
            throw HyperDRError(code: "out_of_memory", message: "Unable to create Metal frame buffer")
        }
        return buffer
    }
}

public final class PreviewFrame: Sendable {
    public let trace: PreviewTrace?
    public let metadata: PreviewMetadata
    public let metadataJSON: Data
    public let base, gain: FramePlane
    // Internal for @testable ownership verification; never expose native handles.
    let storage: FrameStorage
    init(storage: FrameStorage, trace: PreviewTrace? = nil) throws {
        self.trace = trace
        self.storage = storage
        guard let json = storage.value.metadata_json else {
            throw HyperDRError(code: "internal_error", message: "Missing frame metadata")
        }
        metadataJSON = Data(bytes: json, count: strlen(json))
        metadata = try decodeJSON(PreviewMetadata.self, metadataJSON)
        base = try FramePlane(storage: storage, isBase: true)
        gain = try FramePlane(storage: storage, isBase: false)
    }
    public var isCompact: Bool { metadata.schema == "hyperdr.native-preview/v2" }
    /// Zero-copy. Each MTLBuffer retains native storage through its deallocator.
    /// Use normal retained-reference command buffers: NEVER use
    /// makeCommandBufferWithUnretainedReferences(). Release after GPU completion.
    public func metalBuffers(device: any MTLDevice, trace: PreviewTrace? = nil) throws -> (base: any MTLBuffer, gain: any MTLBuffer) {
        let trace = trace ?? self.trace
        let interval = trace?.begin("metalBuffers")
        defer { if let interval { trace?.end("metalBuffers", interval) } }
        return (try base.metalBuffer(device: device), try gain.metalBuffer(device: device))
    }
}

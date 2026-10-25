import Foundation
import HyperDREngineCore

/// One caller-owned plane of interleaved float32 samples, laid out for
/// `hyperdr_package`: the SDR base, or the gain plane in log2 stops.
///
/// The wrapper copies nothing, so the buffer must stay valid and unmodified for
/// the duration of the `package` call, exactly as with a texture still being
/// read on the GPU. Rows are tightly packed (`width * channels` samples).
public struct PackagePlane: @unchecked Sendable {
    public let samples: UnsafeBufferPointer<Float>
    public let width: Int
    public let height: Int
    public let channels: Int

    public init(samples: UnsafeBufferPointer<Float>, width: Int, height: Int, channels: Int) {
        self.samples = samples
        self.width = width
        self.height = height
        self.channels = channels
    }

    func validated(_ what: String) throws {
        guard width > 0, height > 0, channels > 0 else {
            throw HyperDRError(code: "invalid_options", message: "The \(what) plane has an empty dimension")
        }
        guard samples.count >= width * height * channels else {
            throw HyperDRError(code: "invalid_options",
                               message: "The \(what) plane holds \(samples.count) samples; \(width * height * channels) are needed")
        }
    }
}

/// The ISO 21496-1 parameters that describe a gain plane.
public struct PackageGainMetadata: Sendable {
    /// One value per gain channel; a one-channel plane uses the first only.
    public var baseOffsets: [Float]
    public var alternateOffsets: [Float]
    /// Log2 stops. A base rendition of SDR white has zero base headroom.
    public var baseHeadroom: Float
    /// Log2 stops the pair can reach. The adaptive format writes this as its
    /// declared capacity and refuses a gain above it.
    public var alternateHeadroom: Float
    /// The space the ratios were measured in. Only the base's own is accepted.
    public var workingGamut: String

    public init(baseOffsets: [Float] = [0, 0, 0], alternateOffsets: [Float] = [0, 0, 0],
                baseHeadroom: Float = 0, alternateHeadroom: Float,
                workingGamut: String = "display-p3") {
        self.baseOffsets = baseOffsets
        self.alternateOffsets = alternateOffsets
        self.baseHeadroom = baseHeadroom
        self.alternateHeadroom = alternateHeadroom
        self.workingGamut = workingGamut
    }
}

/// Encoding parameters for one package call. Format ids are the engine's:
/// `adaptive`, `iso-gainmap-jpeg`, `pq`, `hlg`, `avif-pq`, `avif-hlg`,
/// `sdr-jpeg`, `sdr-tiff`.
public struct PackageOptions: Sendable {
    public var format: String
    public var quality: Int
    /// Base bit depth for `adaptive`; 8 or 10.
    public var depth: Int
    /// `srgb` or `p3` for the SDR formats; the format default when nil.
    public var gamut: String?
    public var verify: Bool
    public var overwrite: Bool
    /// The planes already carry the presentation frame, because the render
    /// graph composites the mat before packaging. E5 then applies here too: the
    /// gain codebook keeps an exact zero-gain code at gamma 1, so the mat stays
    /// SDR. A framed pair must also use equal base and alternate offsets.
    public var presentationFrame: Bool
    /// The photograph's rectangle inside the SDR base. Setting it asks for the
    /// E5 readback as well: the mat outside it must carry no gain after the
    /// file is decoded, which costs one extra decode. Needs `presentationFrame`
    /// and a format that stores a gain map.
    public var framePhoto: FrameLayout.Rect?
    /// Optional serialized Exif block from the source. The writer re-emits the
    /// safe portable subset with orientation 1, because the planes are upright.
    public var exif: Data?

    public init(format: String, quality: Int = 90, depth: Int = 8,
                gamut: String? = nil, verify: Bool = true, overwrite: Bool = false,
                presentationFrame: Bool = false, framePhoto: FrameLayout.Rect? = nil,
                exif: Data? = nil) {
        self.format = format
        self.quality = quality
        self.depth = depth
        self.gamut = gamut
        self.verify = verify
        self.overwrite = overwrite
        self.presentationFrame = presentationFrame
        self.framePhoto = framePhoto
        self.exif = exif
    }

    var parameters: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "quality": .number(Double(quality)),
            "depth": .number(Double(depth)),
            "verify": .bool(verify),
            "overwrite": .bool(overwrite)]
        if let gamut { values["gamut"] = .string(gamut) }
        return values
    }
}

/// What `hyperdr_package` wrote (`hyperdr.package/v1`).
public struct PackageReport: Codable, Sendable {
    public struct Metadata: Codable, Sendable {
        public let exif: Bool
        public let icc: String
    }
    /// The gain parameters as stored, not as requested.
    public struct Gain: Codable, Sendable {
        public let stored: Bool
        public let channels, width, height: Int
        public let gainMin, gainMax, gamma: Double
        public let baseOffsets, alternateOffsets: [Double]
        public let baseHeadroom, alternateHeadroom: Double
        /// Samples the writer had to clamp, for example a negative gain in the
        /// adaptive format, which stores no signed gain.
        public let clippedSamples: Int
    }
    public let schema, output, format: String
    public let width, height, bytes: Int
    public let verified: Bool
    /// The check that ran: `heic-gain-map`, `iso-gainmap-jpeg`, `avif`,
    /// `heic-bt2100`, `sdr-jpeg`, `sdr-tiff`, or `skipped`.
    public let verification: String
    public let metadata: Metadata
    /// Absent for the SDR formats, which store no gain.
    public let gain: Gain?
    public internal(set) var rawJSON = Data()
    private enum CodingKeys: String, CodingKey {
        case schema, output, format, width, height, bytes, verified, verification, metadata, gain
    }
}

/// Repeatable synchronous row producer, running on the native package thread.
/// Fill the borrowed tightly packed RGB base and optional log2 gain buffers.
/// Requests may revisit rows; preserve the frozen source/recipe for this call.
public typealias PackageRowReader = @Sendable (_ y: Int, _ rows: Int,
    _ base: UnsafeMutableBufferPointer<Float>, _ gain: UnsafeMutableBufferPointer<Float>?) throws -> Void

/// A row writer's independent units once its rows are read: AVIF grid cells,
/// each encoded and then verified (on a second thread, beside the next encode).
public enum PackagePhase: UInt32, Sendable {
    case encode = 1, verify = 2
}

/// Called on the native package thread, between units; `done` never decreases
/// within a phase and reaches `total`. Return quickly; never call the engine.
public typealias PackageProgressHandler = @Sendable (_ phase: PackagePhase, _ done: Int, _ total: Int) -> Void

private final class PackageRowContext {
    let width: Int
    let channels: Int
    let read: PackageRowReader
    let progress: PackageProgressHandler?
    var failure: (any Error)?
    init(width: Int, channels: Int, read: @escaping PackageRowReader, progress: PackageProgressHandler?) {
        self.width = width; self.channels = channels; self.read = read; self.progress = progress
    }
}

extension Engine {
    /// Writes an already-rendered SDR base plus gain plane (P7).
    ///
    /// The engine quantizes and dithers the gain codes, writes the container
    /// with the same encoders a convert uses, verifies the file by decoding it,
    /// and reports what it stored. A pair the chosen format cannot represent is
    /// refused with `unsupported_format` rather than approximated.
    ///
    /// Runs on the engine queue and forwards `Task` cancellation.
    public func package(sdr: PackagePlane, gain: PackagePlane? = nil,
                        gainMetadata: PackageGainMetadata? = nil,
                        to output: URL, options: PackageOptions) async throws -> PackageReport {
        try sdr.validated("SDR base")
        if let gain { try gain.validated("gain") }
        guard (gain == nil) == (gainMetadata == nil) else {
            throw HyperDRError(code: "invalid_options",
                               message: "A gain plane and its ISO 21496-1 metadata travel together")
        }
        if options.framePhoto != nil && !options.presentationFrame {
            throw HyperDRError(code: "invalid_options",
                               message: "A frame photograph rectangle needs presentationFrame")
        }
        let parameters = try encodeJSON(options.parameters)
        let exif = options.exif ?? Data()
        return try await EngineExecutor.run { cancellation in
            try Self.packageNow(engine: self.pointer, sdr: sdr, gain: gain,
                                gainMetadata: gainMetadata, output: output,
                                format: options.format, parameters: parameters,
                                presentationFrame: options.presentationFrame,
                                framePhoto: options.framePhoto,
                                exif: exif, cancellation: cancellation)
        }
    }

    /// Runtime HEVC encoder availability is still checked by encoder capabilities.
    public static func supportsPackageRows(format: String) -> Bool {
        format.withCString { hyperdr_package_rows_supported($0) != 0 }
    }

    /// Packages repeatable bands without caller-owned whole float planes. AVIF
    /// stages quantized rows on disk, then encodes one cell at a time while the
    /// previous cell is verified, reporting both through `progress`.
    /// A separate system reader may still need native-area decoder workspace.
    public func packageRows(width: Int, height: Int, gainChannels: Int = 0,
                            gainMetadata: PackageGainMetadata? = nil, rows: Int = 256,
                            to output: URL, options: PackageOptions,
                            read: @escaping PackageRowReader,
                            progress: PackageProgressHandler? = nil) async throws -> PackageReport {
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              rows > 0, rows <= 4096, [0, 1, 3].contains(gainChannels),
              (gainChannels == 0) == (gainMetadata == nil) else {
            throw HyperDRError(code: "invalid_options", message: "Invalid package band dimensions or gain metadata")
        }
        let base = PackagePlane(samples: UnsafeBufferPointer(start: nil, count: 0), width: width, height: height, channels: 3)
        let gain = gainChannels == 0 ? nil : PackagePlane(samples: UnsafeBufferPointer(start: nil, count: 0),
            width: width, height: height, channels: gainChannels)
        let parameters = try encodeJSON(options.parameters)
        return try await EngineExecutor.run { cancellation in
            try Self.packageNow(engine: self.pointer, sdr: base, gain: gain, gainMetadata: gainMetadata,
                output: output, format: options.format, parameters: parameters,
                presentationFrame: options.presentationFrame, framePhoto: options.framePhoto,
                exif: options.exif ?? Data(), cancellation: cancellation, reader: read, progress: progress, rows: rows)
        }
    }

    /// The C struct has room for three channels; a caller with one value means
    /// that value for all of them (only the first is stored for a mono map).
    private static func channels3(_ values: [Float]) -> (Float, Float, Float) {
        func value(_ index: Int) -> Float {
            values.isEmpty ? 0 : values[min(index, values.count - 1)]
        }
        return (value(0), value(1), value(2))
    }

    private static func packageNow(engine: OpaquePointer, sdr: PackagePlane, gain: PackagePlane?,
                                   gainMetadata: PackageGainMetadata?, output: URL,
                                   format: String, parameters: String,
                                   presentationFrame: Bool, framePhoto: FrameLayout.Rect?,
                                   exif: Data,
                                   cancellation: Cancellation, reader: PackageRowReader? = nil,
                                   progress: PackageProgressHandler? = nil, rows: Int = 256) throws -> PackageReport {
        var base = hyperdr_package_plane()
        base.data = UnsafeRawPointer(sdr.samples.baseAddress)
        base.row_bytes = 0
        base.size = sdr.samples.count * MemoryLayout<Float>.size
        base.width = UInt32(sdr.width)
        base.height = UInt32(sdr.height)
        base.channels = UInt32(sdr.channels)
        base.format = UInt32(HYPERDR_PLANE_F32)

        var gainPlane = hyperdr_package_plane()
        gainPlane.data = gain.flatMap { UnsafeRawPointer($0.samples.baseAddress) }
        gainPlane.row_bytes = 0
        gainPlane.size = (gain?.samples.count ?? 0) * MemoryLayout<Float>.size
        gainPlane.width = UInt32(gain?.width ?? 0)
        gainPlane.height = UInt32(gain?.height ?? 0)
        gainPlane.channels = UInt32(gain?.channels ?? 0)
        gainPlane.format = UInt32(HYPERDR_PLANE_F32)

        var gainSettings = hyperdr_package_gain()
        gainSettings.plane = gainPlane
        gainSettings.base_offset = channels3(gainMetadata?.baseOffsets ?? [])
        gainSettings.alternate_offset = channels3(gainMetadata?.alternateOffsets ?? [])
        gainSettings.base_headroom = gainMetadata?.baseHeadroom ?? 0
        gainSettings.alternate_headroom = gainMetadata?.alternateHeadroom ?? 0
        let gamut = gainMetadata?.workingGamut ?? "display-p3"

        let rowContext = reader.map {
            PackageRowContext(width: sdr.width, channels: gain?.channels ?? 0, read: $0, progress: progress)
        }
        var reportPointer: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<hyperdr_error>?
        let status: Int32 = output.path.withCString { path in
            format.withCString { format in
                parameters.withCString { parameters in
                    gamut.withCString { gamut in
                        // The C struct points at this CString, so the name has to
                        // be assigned while the buffer is alive: an unset field
                        // makes the engine fall back to "display-p3" and accept a
                        // grid it should have refused.
                        gainSettings.working_gamut = gamut
                        return exif.withUnsafeBytes { exifBytes in
                            withUnsafePointer(to: base) { basePointer in
                                withUnsafePointer(to: gainSettings) { gainPointer in
                                    var request = hyperdr_package_request()
                                    request.output_path = path
                                    request.format = format
                                    request.parameters_json = parameters
                                    request.sdr = basePointer
                                    request.gain = gain == nil ? nil : gainPointer
                                    request.exif = exifBytes.baseAddress
                                    request.exif_size = exifBytes.count
                                    request.presentation_frame = presentationFrame ? 1 : 0
                                    if let framePhoto {
                                        request.has_frame_photo = 1
                                        request.frame_photo.x = UInt32(framePhoto.x)
                                        request.frame_photo.y = UInt32(framePhoto.y)
                                        request.frame_photo.width = UInt32(framePhoto.width)
                                        request.frame_photo.height = UInt32(framePhoto.height)
                                    }
                                    request.cancel = cancellation.pointer
                                    if let rowContext {
                                        let report: hyperdr_package_progress_callback? = progress == nil ? nil : { user, phase, done, total in
                                            let context = Unmanaged<PackageRowContext>.fromOpaque(user!).takeUnretainedValue()
                                            guard let phase = PackagePhase(rawValue: phase) else { return }
                                            context.progress?(phase, Int(done), Int(total))
                                        }
                                        return hyperdr_package_rows_progress(engine, &request, UInt32(rows), { user, y, count, base, gain in
                                            let context = Unmanaged<PackageRowContext>.fromOpaque(user!).takeUnretainedValue()
                                            do {
                                                let pixels = context.width * Int(count)
                                                try context.read(Int(y), Int(count),
                                                    UnsafeMutableBufferPointer(start: base, count: pixels * 3),
                                                    gain.map { UnsafeMutableBufferPointer(start: $0, count: pixels * context.channels) })
                                                return 0
                                            } catch {
                                                context.failure = error
                                                return 1
                                            }
                                        }, report, Unmanaged.passUnretained(rowContext).toOpaque(), &reportPointer, &error)
                                    }
                                    return hyperdr_package(engine, &request, &reportPointer, &error)
                                }
                            }
                        }
                    }
                }
            }
        }
        // The report and error are freed after this function returns, so read
        // the status first and keep the string alive until the caller has it.
        if status != 0 {
            defer { if let reportPointer { hyperdr_string_free(reportPointer) } }
            if let failure = rowContext?.failure {
                hyperdr_error_free(error)
                throw failure
            }
            try checkStatus(status, error)
            throw HyperDRError(code: "internal_error", message: "Packaging failed without an error")
        }
        guard let reportPointer else {
            hyperdr_error_free(error)
            throw HyperDRError(code: "internal_error", message: "Missing package report")
        }
        defer { hyperdr_string_free(reportPointer) }
        hyperdr_error_free(error)
        let bytes = Data(bytes: reportPointer, count: strlen(reportPointer))
        var report = try decodeJSON(PackageReport.self, bytes)
        report.rawJSON = bytes
        return report
    }
}

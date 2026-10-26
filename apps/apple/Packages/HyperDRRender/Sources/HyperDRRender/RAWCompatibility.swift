import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A DNG that can be handed to CIRAWFilter in place of an unsupported RAW.
public struct RAWConvertedDNG: Sendable {
    public let url: URL
    public let converterID: String
    public let usedCache: Bool

    public init(url: URL, converterID: String, usedCache: Bool = false) {
        self.url = url
        self.converterID = converterID
        self.usedCache = usedCache
    }
}

/// A full-size embedded JPEG, used as an SDR photograph when no DNG can be made.
public struct RAWEmbeddedPreview: Sendable {
    public let url: URL
    public let usedCache: Bool
    /// EXIF orientation reported by the RAW container, when ImageIO does not
    /// carry it in the extracted JPEG itself.
    public let orientation: Int32?

    public init(url: URL, usedCache: Bool = false, orientation: Int32? = nil) {
        self.url = url
        self.usedCache = usedCache
        self.orientation = orientation
    }
}

/// Implemented by Kit with HyperDREngine. Render owns the policy so every RAW
/// caller (canvas, analysis, detail and export) gets the same source.
public protocol RAWCompatibilityConverting: Sendable {
    var converterID: String { get }
    func convertDNG(from source: URL) async throws -> RAWConvertedDNG
    func extractEmbeddedPreview(from source: URL) async throws -> RAWEmbeddedPreview
}

/// The conversion service can distinguish an absent preview from an I/O failure.
public enum RAWCompatibilityError: Error, Sendable {
    case noPreview
}

private struct RAWCompatibilityIdentity: Hashable {
    let path: String
    let revision: SourceRevision
}

private struct RAWCompatibilityEntry {
    var dng: [String: URL] = [:]
    var preview: URL?
    var latest: URL?
}

/// Process-wide because an export has its own RenderEngine. The URLs point to
/// Kit's bounded decode cache; original file revisions remain part of the key.
private final class RAWCompatibilityRuntime: @unchecked Sendable {
    let lock = NSLock()
    var converter: (any RAWCompatibilityConverting)?
    var forced = false
    var entries: [RAWCompatibilityIdentity: RAWCompatibilityEntry] = [:]
}

extension RenderEngine {
    private static let compatibilityRuntime = RAWCompatibilityRuntime()

    /// Debug/testing escape hatch, also set by -HyperDRForceRAWCompatibility.
    public nonisolated static var forcesRAWCompatibility: Bool {
        get { compatibilityRuntime.lock.withLock { compatibilityRuntime.forced } }
        set { compatibilityRuntime.lock.withLock { compatibilityRuntime.forced = newValue } }
    }

    /// Apps register Kit's engine-backed implementation during startup.
    public nonisolated static func registerRAWCompatibilityConverter(
        _ converter: (any RAWCompatibilityConverting)?
    ) {
        compatibilityRuntime.lock.withLock { compatibilityRuntime.converter = converter }
    }

    static func compatibilityConverter() -> (any RAWCompatibilityConverting)? {
        compatibilityRuntime.lock.withLock { compatibilityRuntime.converter }
    }

    private static func compatibilityIdentity(_ url: URL, revision: SourceRevision) -> RAWCompatibilityIdentity {
        RAWCompatibilityIdentity(path: url.standardizedFileURL.path, revision: revision)
    }

    static func storeCompatibility(_ url: URL, at original: URL, revision: SourceRevision,
                                   kind: SourceCompatibility, converterID: String? = nil) {
        let key = compatibilityIdentity(original, revision: revision)
        compatibilityRuntime.lock.withLock {
            var entry = compatibilityRuntime.entries[key] ?? RAWCompatibilityEntry()
            switch kind {
            case .convertedDNG:
                guard let converterID else { return }
                entry.dng[converterID] = url
            case .embeddedPreview:
                entry.preview = url
            }
            entry.latest = url
            compatibilityRuntime.entries[key] = entry
        }
    }

    static func resolvedCompatibility(_ original: URL, revision: SourceRevision,
                                      kind: SourceCompatibility, converterID: String? = nil) -> URL? {
        let key = compatibilityIdentity(original, revision: revision)
        return compatibilityRuntime.lock.withLock {
            guard let entry = compatibilityRuntime.entries[key] else { return nil }
            switch kind {
            case .convertedDNG: return converterID.flatMap { entry.dng[$0] }
            case .embeddedPreview: return entry.preview
            }
        }
    }

    /// The converted file whose Exif can fill fields absent from the original.
    /// This is a cache lookup only; it never starts a conversion.
    public nonisolated static func rawCompatibilitySourceURL(for original: URL) -> URL? {
        guard let revision = try? SourceRevision(url: original) else { return nil }
        let key = compatibilityIdentity(original, revision: revision)
        return compatibilityRuntime.lock.withLock { compatibilityRuntime.entries[key]?.latest }
    }

    static func isRAWSource(_ url: URL, options: SourceOptions) -> Bool {
        guard options.kind != .imageIO else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) else { return options.kind == .raw }
        return options.kind == .raw || UTType(identifier as String)?.conforms(to: .rawImage) == true
    }

    static func requireCompatibilityConverter(_ id: String) throws -> any RAWCompatibilityConverting {
        guard let converter = compatibilityConverter(), converter.converterID == id else {
            throw RenderError.unsupportedRAWCompatibility(id)
        }
        return converter
    }

    /// Validate a recorded converter before a materialized source cache can
    /// satisfy the open. A saved edit never silently moves to another version.
    static func validateRecordedCompatibility(_ options: SourceOptions) throws {
        if let id = options.rawCompatibility { _ = try requireCompatibilityConverter(id) }
    }

    /// Prepare only paths that must not try Apple's decoder first. Ordinary
    /// new photos still attempt the system before any conversion work.
    static func prepareRequiredCompatibility(_ url: URL, options: SourceOptions,
                                             revision: SourceRevision,
                                             progress: (@Sendable (SourceLoadPhase) -> Void)?) async throws -> SourceOptions {
        guard isRAWSource(url, options: options) else { return options }
        if options.rawEmbeddedPreview {
            return try await useEmbeddedPreview(url, options: options, revision: revision,
                                                progress: progress)
        }
        if let id = options.rawCompatibility {
            let converter = try requireCompatibilityConverter(id)
            return try await useConvertedDNG(url, options: options, revision: revision,
                                             converter: converter, progress: progress)
        }
        if forcesRAWCompatibility {
            return try await recoverRAW(url, options: options, revision: revision, progress: progress)
        }
        return options
    }

    /// Open with the same compatibility policy for canvas and export. A native
    /// decode failure is the only ordinary path that starts a conversion.
    static func openWithCompatibility(_ url: URL, options: SourceOptions, deferred: Bool = false,
                                      allowsFallback: Bool, retryNativeDecoder: Bool,
                                      revision: SourceRevision,
                                      progress: (@Sendable (SourceLoadPhase) -> Void)? = nil) async throws
        -> (opened: OpenedSource, options: SourceOptions) {
        let recordedConversion = options.rawCompatibility != nil
        var options = try await prepareRequiredCompatibility(url, options: options, revision: revision, progress: progress)
        guard isRAWSource(url, options: options) else {
            return (try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }, options)
        }
        if !allowsFallback, options.rawCompatibility == nil, !options.rawEmbeddedPreview,
           let version = options.rawDecoderVersion, CIRAWFilter(imageURL: url) == nil {
            throw RenderError.unsupportedRAWDecoder(version)
        }
        if options.rawCompatibility != nil {
            return try openRecoveredDNG(url, options: options, deferred: deferred,
                allowAutomaticDecoderFallback: retryNativeDecoder && !recordedConversion, revision: revision, progress: progress)
        }
        if options.rawEmbeddedPreview || !allowsFallback {
            let opened = try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }
            return (opened, options)
        }
        do {
            let opened = try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }
            return (opened, options)
        } catch RenderError.cannotDecodeSource {
            // Preserve the existing new-photo Automatic policy: decoder 8 on
            // the original file gets its one chance before LibRaw is involved.
            if retryNativeDecoder, !forcesRAWCompatibility,
               options.rawDecoderVersion?.split(separator: ".").first == "9" {
                throw RenderError.cannotDecodeSource
            }
            options = try await recoverRAW(url, options: options, revision: revision, progress: progress)
            if options.rawCompatibility != nil {
                return try openRecoveredDNG(url, options: options, deferred: deferred,
                    allowAutomaticDecoderFallback: retryNativeDecoder, revision: revision, progress: progress)
            }
            let opened = try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }
            return (opened, options)
        }
    }

    private static func openRecoveredDNG(_ url: URL, options: SourceOptions, deferred: Bool,
                                         allowAutomaticDecoderFallback: Bool, revision: SourceRevision,
                                         progress: (@Sendable (SourceLoadPhase) -> Void)?) throws
        -> (opened: OpenedSource, options: SourceOptions) {
        do {
            let opened = try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }
            return (opened, options)
        } catch RenderError.cannotDecodeSource {
            guard allowAutomaticDecoderFallback,
                  options.rawDecoderVersion?.split(separator: ".").first == "9",
                  let id = options.rawCompatibility,
                  let converted = resolvedCompatibility(url, revision: revision, kind: .convertedDNG, converterID: id),
                  let filter = CIRAWFilter(imageURL: converted),
                  let fallback = selectRAWDecoder(supported: filter.supportedDecoderVersions.map(\.rawValue),
                      systemDefault: filter.decoderVersion.rawValue, allowing9: false) else { throw RenderError.cannotDecodeSource }
            var options = options
            options.rawDecoderVersion = fallback
            let opened = try autoreleasepool { try Self.open(url, options: options, deferred: deferred, progress: progress) }
            return (opened, options)
        }
    }

    private static func recoverRAW(_ url: URL, options: SourceOptions, revision: SourceRevision,
                                   progress: (@Sendable (SourceLoadPhase) -> Void)?) async throws -> SourceOptions {
        guard let converter = compatibilityConverter() else { throw RenderError.cannotDecodeSource }
        do {
            return try await useConvertedDNG(url, options: options, revision: revision,
                                             converter: converter, progress: progress)
        } catch RenderError.rawUnsupported(let camera) {
            do {
                return try await useEmbeddedPreview(url, options: options, revision: revision,
                                                    progress: progress)
            } catch RAWCompatibilityError.noPreview {
                throw RenderError.rawUnsupported(camera: camera)
            } catch RenderError.rawUnsupported(let previewCamera) {
                throw RenderError.rawUnsupported(camera: camera ?? previewCamera)
            }
        }
    }

    private static func useConvertedDNG(_ url: URL, options: SourceOptions, revision: SourceRevision,
                                        converter: any RAWCompatibilityConverting,
                                        progress: (@Sendable (SourceLoadPhase) -> Void)?) async throws -> SourceOptions {
        if let recorded = options.rawCompatibility, recorded != converter.converterID {
            throw RenderError.unsupportedRAWCompatibility(recorded)
        }
        let began = ContinuousClock.now
        let converted = try await converter.convertDNG(from: url)
        guard converted.converterID == converter.converterID else {
            throw RenderError.unsupportedRAWCompatibility(options.rawCompatibility ?? converter.converterID)
        }
        storeCompatibility(converted.url, at: url, revision: revision,
                           kind: .convertedDNG, converterID: converted.converterID)
        let elapsed = began.duration(to: .now).timeInterval
        progress?(.rawCompatibility(.convertedDNG, elapsed, converted.usedCache))
        var options = options
        let wasRecorded = options.rawCompatibility != nil
        options.rawCompatibility = converted.converterID
        options.rawEmbeddedPreview = false
        if !wasRecorded {
            options.rawDecoderVersion = try decoderForConvertedDNG(converted.url, requested: options.rawDecoderVersion)
        }
        return options
    }

    private static func useEmbeddedPreview(_ url: URL, options: SourceOptions, revision: SourceRevision,
                                           progress: (@Sendable (SourceLoadPhase) -> Void)?) async throws -> SourceOptions {
        guard let converter = compatibilityConverter() else { throw RenderError.cannotDecodeSource }
        let began = ContinuousClock.now
        let preview = try await converter.extractEmbeddedPreview(from: url)
        storeCompatibility(preview.url, at: url, revision: revision, kind: .embeddedPreview)
        let elapsed = began.duration(to: .now).timeInterval
        progress?(.rawCompatibility(.embeddedPreview, elapsed, preview.usedCache))
        var options = options
        options.rawCompatibility = nil
        options.rawEmbeddedPreview = true
        options.rawDecoderVersion = nil
        options.embeddedPreviewOrientation = preview.orientation
        options.sceneLinear = false
        options.draftRAWPreview = false
        return options
    }

    /// A version selected on the original maps by generation to the DNG's own
    /// spelling (9 -> 9.dng). Recorded converted recipes instead use the exact
    /// version in openRAW, just like native saved recipes.
    private static func decoderForConvertedDNG(_ url: URL, requested: String?) throws -> String? {
        guard let filter = CIRAWFilter(imageURL: url) else { throw RenderError.cannotDecodeSource }
        let supported = filter.supportedDecoderVersions.map(\.rawValue)
        if let requested {
            let generation = requested.split(separator: ".").first
            guard let version = supported.first(where: {
                $0 == requested || $0.split(separator: ".").first == generation
            }) else { throw RenderError.unsupportedRAWDecoder(requested) }
            return version
        }
        return selectRAWDecoder(supported: supported, systemDefault: filter.decoderVersion.rawValue)
    }

    /// Selection runs before the first open. If Apple has no usable filter,
    /// select on the converted DNG and retain its identity for the actual load;
    /// a conversion failure returns nil so the normal open can report the
    /// embedded-preview result or its final error.
    static func decoderSelection(_ url: URL) async throws -> (url: URL, converterID: String?)? {
        if !forcesRAWCompatibility, usableSelectionFilter(url) != nil { return (url, nil) }
        guard compatibilityConverter() != nil else { return nil }
        let revision = try SourceRevision(url: url)
        do {
            var options = SourceOptions(kind: .raw)
            options = try await recoverRAW(url, options: options, revision: revision, progress: nil)
            guard !options.rawEmbeddedPreview, let converterID = options.rawCompatibility,
                  let converted = resolvedCompatibility(url, revision: revision, kind: .convertedDNG,
                                                        converterID: converterID) else { return nil }
            return (converted, converterID)
        } catch RenderError.rawUnsupported {
            return nil
        }
    }

    /// LibRaw chosen for a new photo: unpack it with the registered converter
    /// and develop the DNG with its own newest generation (9.dng, else 8.dng),
    /// so every camera's colour comes from the same generic matrix path. A DNG
    /// original already takes that path and keeps Apple's preferred decoder.
    /// Nil when LibRaw cannot read the camera; the caller chooses what follows.
    public func libRAWDecoderSelection(_ url: URL) async throws -> RAWDecoderSelection? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String), type.conforms(to: .rawImage) else { return RAWDecoderSelection() }
        if let dng = UTType("com.adobe.raw-image"), type.conforms(to: dng) {
            return RAWDecoderSelection(version: await preferredRAWDecoder(url))
        }
        guard let converter = Self.compatibilityConverter() else { throw RenderError.cannotDecodeSource }
        let revision = try SourceRevision(url: url)
        do {
            let options = try await Self.useConvertedDNG(url, options: SourceOptions(kind: .raw), revision: revision,
                                                         converter: converter, progress: nil)
            return RAWDecoderSelection(version: options.rawDecoderVersion, converterID: options.rawCompatibility)
        } catch RenderError.rawUnsupported {
            return nil
        }
    }

    /// Whether Apple's own decoder can develop this file without a conversion.
    public nonisolated static func systemDevelops(_ url: URL) -> Bool {
        usableSelectionFilter(url) != nil
    }

    static func usableSelectionFilter(_ url: URL) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url),
              filter.supportedDecoderVersions.contains(where: {
                  !$0.rawValue.isEmpty && $0 != CIRAWDecoderVersion.none
              }),
              let size = try? rawNativeSize(filter.nativeSize, rotated: filter.orientation.rawValue >= 5),
              size.width > 0, size.height > 0 else { return nil }
        return filter
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

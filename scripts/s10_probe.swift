// S10 hosted-runner probe: Metal device and one-frame HEVC 8-bit/Main10 encode.
// This file is intentionally dependency-free so the workflow can run it on a
// stock macOS runner without building HyperDR.

import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

struct ProbeResult: Codable {
    let name: String
    let status: Int32
    let error: String?
    let encodedBytes: Int
    let hardware: Bool?
    let encoderID: String?
    let profileIDC: Int?
    let bitDepthLuma: Int?
    let bitDepthChroma: Int?
    let chromaFormat: Int?
    let profileVerified: Bool
}

private struct HEVCConfiguration {
    let profileIDC: Int
    let bitDepthLuma: Int
    let bitDepthChroma: Int
    let chromaFormat: Int
}

private struct ConfigurationError: Error {
    let message: String
}

private struct CallbackSnapshot {
    let status: OSStatus
    let encodedBytes: Int
    let hasSampleBuffer: Bool
    let configuration: HEVCConfiguration?
    let configurationError: String?
}

/// VT invokes the output handler on its own thread. All fields it touches are
/// guarded here so the waiting thread never reads a partially published frame.
private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = CallbackSnapshot(
        status: noErr, encodedBytes: 0, hasSampleBuffer: false,
        configuration: nil, configurationError: nil)

    func record(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        var bytes = 0
        var configuration: HEVCConfiguration?
        var configurationError: String?
        if status == noErr, let sampleBuffer {
            if let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
                bytes = CMBlockBufferGetDataLength(block)
            }
            if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                switch parseHEVCConfiguration(format) {
                case .success(let value): configuration = value
                case .failure(let error): configurationError = error.message
                }
            } else {
                configurationError = "sample buffer has no format description"
            }
        }
        lock.withLock {
            snapshot = CallbackSnapshot(status: status, encodedBytes: bytes,
                hasSampleBuffer: sampleBuffer != nil, configuration: configuration,
                configurationError: configurationError)
        }
    }

    func value() -> CallbackSnapshot { lock.withLock { snapshot } }
}

private func statusString(_ status: OSStatus) -> String {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
}

private func copyProperty(_ session: VTCompressionSession, _ key: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    let status = withUnsafeMutablePointer(to: &value) { pointer in
        VTSessionCopyProperty(session, key: key, allocator: kCFAllocatorDefault,
                              valueOut: UnsafeMutableRawPointer(pointer))
    }
    return status == noErr ? value : nil
}

private func setProperty(_ session: VTCompressionSession, key: CFString,
                         value: CFTypeRef, phase: String) -> (status: OSStatus, error: String?) {
    let status = VTSessionSetProperty(session, key: key, value: value)
    return (status, status == noErr ? nil : "\(phase): \(statusString(status))")
}

private func parseHEVCConfiguration(_ format: CMFormatDescription) -> Result<HEVCConfiguration, ConfigurationError> {
    guard let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any],
          let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String]
              as? [String: Any],
          let data = (atoms["hvcC"] as? Data) ?? (atoms["hev1"] as? Data) else {
        return .failure(ConfigurationError(message: "format description has no hvcC atom"))
    }
    let bytes = [UInt8](data)
    guard bytes.count >= 23 else { return .failure(ConfigurationError(message: "hvcC is truncated (\(bytes.count) bytes)")) }
    let profileIDC = Int(bytes[1] & 0x1f)
    let chromaFormat = Int(bytes[16] & 0x03)
    let bitDepthLuma = Int(bytes[17] & 0x07) + 8
    let bitDepthChroma = Int(bytes[18] & 0x07) + 8
    return .success(HEVCConfiguration(profileIDC: profileIDC, bitDepthLuma: bitDepthLuma,
        bitDepthChroma: bitDepthChroma, chromaFormat: chromaFormat))
}

private func fillNeutral(_ buffer: CVPixelBuffer, bitDepth: Int) -> Bool {
    guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let planes = CVPixelBufferGetPlaneCount(buffer)
    guard planes == 2 else { return false }
    let value: UInt16 = bitDepth == 10 ? UInt16(512 << 6) : 128
    for plane in 0..<planes {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return false }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        if bitDepth == 10 {
            let count = rowBytes * height / MemoryLayout<UInt16>.size
            base.assumingMemoryBound(to: UInt16.self).initialize(repeating: value, count: count)
        } else {
            memset(base, Int32(value), rowBytes * height)
        }
    }
    return true
}

private func encode(name: String, pixelFormat: OSType, profile: CFString,
                    expectedProfileIDC: Int, bitDepth: Int) -> ProbeResult {
    let width = 512
    let height = 512
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:],
        kCVPixelBufferMetalCompatibilityKey: true,
    ]
    let pixelStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                                         attributes as CFDictionary, &pixelBuffer)
    guard pixelStatus == kCVReturnSuccess, let pixelBuffer, fillNeutral(pixelBuffer, bitDepth: bitDepth) else {
        return ProbeResult(name: name, status: Int32(pixelStatus), error: "pixel buffer creation/fill failed",
                           encodedBytes: 0, hardware: nil, encoderID: nil, profileIDC: nil,
                           bitDepthLuma: nil, bitDepthChroma: nil, chromaFormat: nil,
                           profileVerified: false)
    }

    let encoderSpecification: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
    ]
    var session: VTCompressionSession?
    let createStatus = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
        codecType: kCMVideoCodecType_HEVC,
        encoderSpecification: encoderSpecification as CFDictionary,
        imageBufferAttributes: nil, compressedDataAllocator: nil,
        outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard createStatus == noErr, let session else {
        return ProbeResult(name: name, status: createStatus, error: statusString(createStatus),
                           encodedBytes: 0, hardware: nil, encoderID: nil, profileIDC: nil,
                           bitDepthLuma: nil, bitDepthChroma: nil, chromaFormat: nil,
                           profileVerified: false)
    }
    defer { VTCompressionSessionInvalidate(session) }

    let realTime = setProperty(session, key: kVTCompressionPropertyKey_RealTime,
                               value: kCFBooleanTrue, phase: "set RealTime")
    if let error = realTime.error {
        return ProbeResult(name: name, status: realTime.status, error: error, encodedBytes: 0,
                           hardware: nil, encoderID: nil, profileIDC: nil, bitDepthLuma: nil,
                           bitDepthChroma: nil, chromaFormat: nil, profileVerified: false)
    }
    let profileLevel = setProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                   value: profile, phase: "set ProfileLevel")
    if let error = profileLevel.error {
        return ProbeResult(name: name, status: profileLevel.status, error: error, encodedBytes: 0,
                           hardware: nil, encoderID: nil, profileIDC: nil, bitDepthLuma: nil,
                           bitDepthChroma: nil, chromaFormat: nil, profileVerified: false)
    }
    let reordering = setProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                                 value: kCFBooleanFalse, phase: "set AllowFrameReordering")
    if let error = reordering.error {
        return ProbeResult(name: name, status: reordering.status, error: error, encodedBytes: 0,
                           hardware: nil, encoderID: nil, profileIDC: nil, bitDepthLuma: nil,
                           bitDepthChroma: nil, chromaFormat: nil, profileVerified: false)
    }
    let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepareStatus == noErr else {
        return ProbeResult(name: name, status: prepareStatus, error: statusString(prepareStatus),
                           encodedBytes: 0, hardware: nil, encoderID: nil, profileIDC: nil,
                           bitDepthLuma: nil, bitDepthChroma: nil, chromaFormat: nil,
                           profileVerified: false)
    }

    let semaphore = DispatchSemaphore(value: 0)
    let state = CallbackState()
    let encodeStatus = VTCompressionSessionEncodeFrame(
        session, imageBuffer: pixelBuffer,
        presentationTimeStamp: CMTime(value: 1, timescale: 30),
        duration: CMTime(value: 1, timescale: 30), frameProperties: nil,
        infoFlagsOut: nil) { status, _, sampleBuffer in
            state.record(status: status, sampleBuffer: sampleBuffer)
            semaphore.signal()
        }
    guard encodeStatus == noErr else {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return ProbeResult(name: name, status: encodeStatus, error: statusString(encodeStatus),
                           encodedBytes: 0, hardware: nil, encoderID: nil, profileIDC: nil,
                           bitDepthLuma: nil, bitDepthChroma: nil, chromaFormat: nil,
                           profileVerified: false)
    }

    let waitResult = semaphore.wait(timeout: .now() + 15)
    // CompleteFrames may invoke the callback; read only after it returns, and
    // the callback state is lock-guarded either way.
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    let snapshot = state.value()
    let hardware = (copyProperty(session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder) as? Bool) ?? false
    let encoderID = copyProperty(session, kVTCompressionPropertyKey_EncoderID) as? String

    if waitResult == .timedOut {
        return ProbeResult(name: name, status: -1, error: "timed out waiting for the encoded frame",
                           encodedBytes: snapshot.encodedBytes, hardware: hardware, encoderID: encoderID,
                           profileIDC: snapshot.configuration?.profileIDC,
                           bitDepthLuma: snapshot.configuration?.bitDepthLuma,
                           bitDepthChroma: snapshot.configuration?.bitDepthChroma,
                           chromaFormat: snapshot.configuration?.chromaFormat,
                           profileVerified: false)
    }
    guard snapshot.status == noErr else {
        return ProbeResult(name: name, status: snapshot.status, error: statusString(snapshot.status),
                           encodedBytes: snapshot.encodedBytes, hardware: hardware, encoderID: encoderID,
                           profileIDC: snapshot.configuration?.profileIDC,
                           bitDepthLuma: snapshot.configuration?.bitDepthLuma,
                           bitDepthChroma: snapshot.configuration?.bitDepthChroma,
                           chromaFormat: snapshot.configuration?.chromaFormat,
                           profileVerified: false)
    }
    guard snapshot.hasSampleBuffer, snapshot.encodedBytes > 0 else {
        return ProbeResult(name: name, status: -1, error: "encoder returned no sample data",
                           encodedBytes: snapshot.encodedBytes, hardware: hardware, encoderID: encoderID,
                           profileIDC: snapshot.configuration?.profileIDC,
                           bitDepthLuma: snapshot.configuration?.bitDepthLuma,
                           bitDepthChroma: snapshot.configuration?.bitDepthChroma,
                           chromaFormat: snapshot.configuration?.chromaFormat,
                           profileVerified: false)
    }
    guard let configuration = snapshot.configuration else {
        return ProbeResult(name: name, status: -1,
                           error: snapshot.configurationError ?? "unable to read hvcC",
                           encodedBytes: snapshot.encodedBytes, hardware: hardware, encoderID: encoderID,
                           profileIDC: nil, bitDepthLuma: nil, bitDepthChroma: nil,
                           chromaFormat: nil, profileVerified: false)
    }
    let verified = configuration.profileIDC == expectedProfileIDC
        && configuration.bitDepthLuma == bitDepth
        && configuration.bitDepthChroma == bitDepth
        && configuration.chromaFormat == 1
    let error = verified ? nil : "encoded hvcC profile_idc=\(configuration.profileIDC) "
        + "bitDepth=\(configuration.bitDepthLuma)/\(configuration.bitDepthChroma) "
        + "chromaFormat=\(configuration.chromaFormat); expected profile_idc=\(expectedProfileIDC) "
        + "bitDepth=\(bitDepth)/\(bitDepth) chromaFormat=1"
    return ProbeResult(name: name, status: verified ? noErr : -1, error: error,
                       encodedBytes: snapshot.encodedBytes, hardware: hardware, encoderID: encoderID,
                       profileIDC: configuration.profileIDC,
                       bitDepthLuma: configuration.bitDepthLuma,
                       bitDepthChroma: configuration.bitDepthChroma,
                       chromaFormat: configuration.chromaFormat,
                       profileVerified: verified)
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build-apple/S10"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
let device = MTLCreateSystemDefaultDevice()
print("Metal device: \(device?.name ?? "none")")

let results = [
    encode(name: "HEVC Main8 4:2:0 full-range", pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
           profile: kVTProfileLevel_HEVC_Main_AutoLevel, expectedProfileIDC: 1, bitDepth: 8),
    encode(name: "HEVC Main10 4:2:0 full-range", pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
           profile: kVTProfileLevel_HEVC_Main10_AutoLevel, expectedProfileIDC: 2, bitDepth: 10),
]
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(results)
try data.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent("probe.json"))
for result in results {
    print("\(result.name): status=\(result.status) bytes=\(result.encodedBytes) "
          + "hardware=\(result.hardware.map(String.init) ?? "unknown") "
          + "encoder=\(result.encoderID ?? "unknown") "
          + "profileIDC=\(result.profileIDC.map(String.init) ?? "unknown") "
          + "bitDepth=\(result.bitDepthLuma.map(String.init) ?? "unknown")/"
          + "\(result.bitDepthChroma.map(String.init) ?? "unknown") "
          + "chromaFormat=\(result.chromaFormat.map(String.init) ?? "unknown") "
          + "profileVerified=\(result.profileVerified)")
    if let error = result.error { print("  error: \(error)") }
}

import Foundation
import Metal
import QuartzCore
import XCTest
@testable import HyperDR

/// Waits for a main-actor condition with a hard deadline. Every asynchronous
/// expectation in the app tests goes through this (or `fulfillment(of:)`):
/// never an unbounded `for await`, and never the blocking `wait(for:)`, which
/// would stall the main actor the models run on.
@MainActor func eventually(timeout: Duration = .seconds(2), _ message: String = "condition",
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for \(message)", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Lets main-actor tasks that are already runnable make progress.
@MainActor func settle(_ turns: Int = 20) async {
    for _ in 0..<turns { await Task.yield() }
}

/// A frame clock the test advances. `nextFrame()` returns at the first
/// `tick()` after it was called; a tick with nobody waiting is banked once,
/// like a display frame boundary that already passed. Cancellation resumes the
/// waiter, so a cancelled scheduler never leaves a test hanging.
@MainActor final class ManualFrameTicker: FrameTicker {
    private(set) var ticks = 0
    private(set) var waits = 0
    private var banked = false
    private var waiter: CheckedContinuation<Void, Error>?

    var isWaiting: Bool { waiter != nil }

    func tick() {
        ticks += 1
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            banked = true
        }
    }

    func nextFrame() async throws {
        waits += 1
        if banked {
            banked = false
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

// Headless rendering tests load the app's compiled Metal library explicitly;
// the production initializer continues to load its own bundle by default.
@MainActor func previewTestLibrary() throws -> (any MTLLibrary)? {
    guard let path = ProcessInfo.processInfo.environment["HYPERDR_TEST_METALLIB"] else { return nil }
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    return try device.makeLibrary(URL: URL(fileURLWithPath: path))
}
@MainActor func makePreviewRenderer() throws -> PreviewRenderer {
    try PreviewRenderer(library: previewTestLibrary())
}
func previewFixtureBundle() -> Bundle {
#if SWIFT_PACKAGE
    Bundle.module
#else
    Bundle(for: PreviewShaderTests.self)
#endif
}
/// Optional raw bytes for same-machine before/after checks; no tolerance or
/// float formatting can mask a changed bit in these traces.
func tracePreviewPixels(_ label: String, _ pixels: [Float]) throws {
    guard let path = ProcessInfo.processInfo.environment["HYPERDR_PIXEL_TRACE_DIRECTORY"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try pixels.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent(label + ".f32le")) }
}

/// Counts `nextDrawable` calls, records whether any came from the main thread,
/// and can stand in for the layer asked: a view's own backing layer, outside
/// a window, can block in `nextDrawable` far past its timeout. `block` makes
/// each call wait (a compositor holding drawables); `handsOutNone` returns nil.
nonisolated final class DrawableProbe: @unchecked Sendable {   // all state behind `lock`
    private let lock = NSLock()
    private var _requests = 0, _mainThreadRequests = 0
    private var _last: (any CAMetalDrawable)?
    private var _handsOutNone = false, _blocking = false
    private var _block: TimeInterval = 0
    private let standIn: CAMetalLayer?

    init(standIn: CAMetalLayer? = nil) { self.standIn = standIn }

    var requests: Int { lock.withLock { _requests } }
    var mainThreadRequests: Int { lock.withLock { _mainThreadRequests } }
    var last: (any CAMetalDrawable)? { lock.withLock { _last } }
    var isBlocking: Bool { lock.withLock { _blocking } }
    var handsOutNone: Bool {
        get { lock.withLock { _handsOutNone } }
        set { lock.withLock { _handsOutNone = newValue } }
    }
    var block: TimeInterval {
        get { lock.withLock { _block } }
        set { lock.withLock { _block = newValue } }
    }

    func install(on renderer: PreviewRenderer) {
        renderer.drawableSource = { [self] layer in request(layer) }
    }

    private func request(_ layer: CAMetalLayer) -> (any CAMetalDrawable)? {
        lock.lock()
        _requests += 1
        if Thread.isMainThread { _mainThreadRequests += 1 }
        _blocking = true
        let (none, delay) = (_handsOutNone, _block)
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let drawable = none ? nil : (standIn ?? layer).nextDrawable()
        lock.lock()
        _last = drawable
        _blocking = false
        lock.unlock()
        return drawable
    }
}

/// A display pair from Swift arrays: an RGB base and a gain of one channel or
/// three (RGB), at the gain's own size.
nonisolated func makeDisplayPair(_ device: any MTLDevice, base: [Float], width: Int, height: Int,
                                 gain: [Float], gainWidth: Int? = nil, gainHeight: Int? = nil,
                                 gainChannels: Int = 1, coding: DisplayPair.GainCoding = .log2,
                                 baseOffset: Float = 0, alternateOffset: Float = 0) throws -> DisplayPair {
    func rgba(_ rgb: [Float]) -> [Float] {
        stride(from: 0, to: rgb.count, by: 3).flatMap { [rgb[$0], rgb[$0 + 1], rgb[$0 + 2], 1] }
    }
    let gainWidth = gainWidth ?? width, gainHeight = gainHeight ?? height
    return DisplayPair(
        base: try PreviewRenderer.texture(device: device, width: width, height: height, values: rgba(base)),
        gain: try PreviewRenderer.texture(device: device, width: gainWidth, height: gainHeight,
            values: gainChannels == 1 ? gain : rgba(gain), monochrome: gainChannels == 1),
        coding: coding, baseOffset: SIMD3(repeating: baseOffset),
        alternateOffset: SIMD3(repeating: alternateOffset), alternateHeadroom: 1)
}

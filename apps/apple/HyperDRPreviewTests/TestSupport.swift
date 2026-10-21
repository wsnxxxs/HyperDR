import Foundation
import Metal
import QuartzCore
import Synchronization
import XCTest
import HyperDRRecipe
import HyperDRRender
import HyperDRKit
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

/// A frame clock the test advances (the editor's render pacing). `nextFrame()` returns at the first
/// `tick()` after it was called; a tick with nobody waiting is banked once,
/// like a display frame boundary that already passed. Cancellation resumes the
/// waiter, so a cancelled scheduler never leaves a test hanging.
@MainActor final class ManualFrameTicker: EditorFrameClock {
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
    Bundle(for: PreviewRendererTests.self)
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
                                 baseOffset: Float = 0, alternateOffset: Float = 0,
                                 alternateHeadroom: Double = 1) throws -> DisplayPair {
    func rgba(_ rgb: [Float]) -> [Float] {
        stride(from: 0, to: rgb.count, by: 3).flatMap { [rgb[$0], rgb[$0 + 1], rgb[$0 + 2], 1] }
    }
    let gainWidth = gainWidth ?? width, gainHeight = gainHeight ?? height
    return DisplayPair(
        base: try PreviewRenderer.texture(device: device, width: width, height: height, values: rgba(base)),
        gain: try PreviewRenderer.texture(device: device, width: gainWidth, height: gainHeight,
            values: gainChannels == 1 ? gain : rgba(gain), monochrome: gainChannels == 1),
        coding: coding, baseOffset: SIMD3(repeating: baseOffset),
        alternateOffset: SIMD3(repeating: alternateOffset), alternateHeadroom: alternateHeadroom)
}

/// `FakeEditorRendering` with failures a test can inject: an open that throws
/// for a URL, and renders of a URL's photo that throw (after any hold). With
/// `holdsOpens` set, an open waits until `releaseOpens` (or cancellation).
nonisolated final class ScriptedRendering: EditorRendering, @unchecked Sendable {   // state behind `state`
    let fake = FakeEditorRendering()
    private struct State {
        var openFailures: [URL: any Error] = [:]
        var renderFailures: [URL: any Error] = [:]
        var sources: [UUID: URL] = [:]
        var holdsOpens = false
        var thumbnailHandler: (@Sendable (EditorFrame, HyperDRRender.PixelSize) async -> CGImage?)?
        var thumbnailCalls: [Int] = []
        var heldOpens: [UUID: (url: URL, resume: CheckedContinuation<Void, Error>)] = [:]
    }
    private let state = Mutex(State())

    var holdsOpens: Bool {
        get { state.withLock { $0.holdsOpens } }
        set { state.withLock { $0.holdsOpens = newValue } }
    }

    /// Replaces the fake's thumbnails; nil from it is a failed thumbnail.
    var thumbnailHandler: (@Sendable (EditorFrame, HyperDRRender.PixelSize) async -> CGImage?)? {
        get { state.withLock { $0.thumbnailHandler } }
        set { state.withLock { $0.thumbnailHandler = newValue } }
    }
    /// The longest side asked for, per thumbnail.
    var thumbnailCalls: [Int] { state.withLock { $0.thumbnailCalls } }

    /// True while an open of `url` is held.
    func isHoldingOpen(_ url: URL) -> Bool { state.withLock { $0.heldOpens.values.contains { $0.url == url } } }

    func releaseOpens() {
        let held = state.withLock { state in
            state.holdsOpens = false
            defer { state.heldOpens = [:] }
            return state.heldOpens.values.map(\.resume)
        }
        held.forEach { $0.resume() }
    }

    private func waitIfHeld(_ url: URL) async throws {
        guard holdsOpens else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.heldOpens[id] = (url, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            state.withLock { $0.heldOpens.removeValue(forKey: id) }?.resume.resume(throwing: CancellationError())
        }
    }

    func failOpen(_ url: URL, with error: (any Error)?) { state.withLock { $0.openFailures[url] = error } }
    func failRenders(of url: URL, with error: (any Error)?) { state.withLock { $0.renderFailures[url] = error } }

    func open(_ url: URL, previewSize: HyperDRRender.PixelSize?) async throws -> EditorSource {
        try await waitIfHeld(url)
        if let error = state.withLock({ $0.openFailures[url] }) { throw error }
        let source = try await fake.open(url, previewSize: previewSize)
        state.withLock { $0.sources[source.id] = url }
        return source
    }
    func render(_ request: EditorRenderRequest) async throws -> EditorFrame {
        let frame = try await fake.render(request)
        if let error = state.withLock({ state in state.sources[request.sourceID].flatMap { state.renderFailures[$0] } }) {
            throw error
        }
        return frame
    }
    func sdrThumbnail(_ frame: EditorFrame, maximumSize: HyperDRRender.PixelSize) async throws -> CGImage {
        let handler = state.withLock { state in
            state.thumbnailCalls.append(max(maximumSize.width, maximumSize.height))
            return state.thumbnailHandler
        }
        guard let handler else { return try await fake.sdrThumbnail(frame, maximumSize: maximumSize) }
        guard let image = await handler(frame, maximumSize) else { throw ScriptedFailure() }
        return image
    }
    func predictModelGain(_ request: EditorRenderRequest) async throws { try await fake.predictModelGain(request) }
    func installLUT(_ lut: ColorLUT) async { await fake.installLUT(lut) }
    func close() async { await fake.close() }
}

struct ScriptedFailure: Error, CustomStringConvertible {
    var description: String { "scripted failure" }
}

extension EditorModel {
    /// Writes one recipe value as a control would (one undo step).
    func adjustRecipe(_ id: String, to value: Double) {
        var recipe = editor.recipe
        recipe.setValue(.number(value), for: id)
        editor.setRecipe(recipe)
    }

    func recipeNumber(_ id: String) -> Double? { editor.recipe.value(for: id)?.numberValue }
}

extension FakeEditorServices {
    /// What an export of the model's current edit freezes: a version made
    /// from it matches the edit.
    func exportKey(_ model: EditorModel) async throws -> RecipeExportSnapshot {
        try model.captureExport().snapshot(revision: try await sourceRevision(try XCTUnwrap(model.photo)))
    }
}

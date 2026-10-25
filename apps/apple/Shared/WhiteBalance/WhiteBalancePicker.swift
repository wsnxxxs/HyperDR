import CoreGraphics
import Foundation
import HyperDRDesign
import Metal
import Observation

/// The white balance eyedropper's state, shared by the Mac and the iPad
/// (adjust-controls F1): whether the canvas is waiting for a click, where the
/// pointer or finger is, the loupe's pixels around it, and what the last pick
/// said. The host supplies how a canvas point becomes a point on the photo,
/// which frame the loupe reads and the editor's `pickWhiteBalance`; this class
/// owns the rest, so both hosts behave the same.
///
/// A pick ends the mode: one click, one undo step. `cancel()` (Esc, the button
/// again, another photo, the crop pane) ends it without writing.
@MainActor @Observable final class WhiteBalancePicker {
    /// The canvas is waiting for a click, or a finger is down.
    private(set) var isActive = false
    /// A pick is being sampled; further clicks wait.
    private(set) var isSampling = false
    /// The pointer on the canvas, in the canvas's points; nil off the photo.
    private(set) var hover: CGPoint?
    /// The photo's pixels around `hover`, magnified, once read.
    private(set) var loupe: CGImage?
    /// What the last pick left to say beside the temperature row.
    private(set) var notice: WhiteBalancePicking.Notice?

    /// A canvas point on the photo as shown, 0…1 from the top left; nil outside it.
    @ObservationIgnored var photoPoint: (CGPoint) -> CGPoint? = { _ in nil }
    /// The frame the canvas draws under a canvas point, whose pixels the loupe magnifies.
    @ObservationIgnored var texture: (CGPoint) -> (any MTLTexture)? = { _ in nil }
    /// The editor's sampling: writes the white balance as one undo step.
    @ObservationIgnored var pick: (CGPoint) async throws -> WhiteBalancePick = { _ in .applied }

    /// Pixels on a side of the loupe's patch (odd: the middle one is the pick).
    static let patch = 15
    @ObservationIgnored private var latest: CGPoint?
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var clearing: Task<Void, Never>?
    /// Counts the modes ended by `reset`; a pick still being sampled from an
    /// earlier one finds it changed and leaves the state alone.
    @ObservationIgnored private var generation = 0

    var picking: WhiteBalancePicking {
        WhiteBalancePicking(isActive: isActive, notice: notice) { [weak self] in self?.toggle() }
    }

    func toggle() {
        isActive ? cancel() : begin()
    }

    /// Called when the mode turns on, so a host can end the others.
    @ObservationIgnored var onBegin: () -> Void = {}

    func begin() {
        guard !isActive else { return }
        onBegin()
        clearNotice()
        isActive = true
    }

    /// Ends the mode without writing. Not while a pick is being sampled: that
    /// one finishes and says what it did.
    func cancel() {
        guard isActive, !isSampling else { return }
        end()
    }

    /// Another photo, the crop pane or a locked editor: ends the mode and drops
    /// any notice, even while a pick is being sampled. That pick may still reach
    /// the recipe, but it no longer ends a later mode or writes its notice.
    func reset() {
        generation += 1
        isSampling = false
        end()
        clearNotice()
    }

    private func end() {
        isActive = false
        hover = nil
        loupe = nil
        latest = nil
        reading?.cancel()
        reading = nil
    }

    /// The pointer or finger moved to `point` (canvas points), or left the canvas.
    func move(to point: CGPoint?) {
        guard isActive, !isSampling else { return }
        guard let point, let fraction = photoPoint(point) else {
            hover = nil
            loupe = nil
            latest = nil
            return
        }
        hover = point
        latest = fraction
        readLoupe()
    }

    /// The click (or lift of the finger) at `point`: samples there and ends the mode.
    func click(at point: CGPoint) {
        guard isActive, !isSampling, let fraction = photoPoint(point) else { return }
        isSampling = true
        let pick = pick
        let token = generation
        Task { @MainActor in
            let result: WhiteBalancePicking.Notice?
            do {
                result = try await pick(fraction) == .clamped ? .clamped : nil
            } catch {
                result = .failed
            }
            guard token == generation else { return }
            notice = result
            isSampling = false
            end()
            if notice != nil { clearNotice(after: .seconds(8)) }
        }
    }

    private func clearNotice(after delay: Duration? = nil) {
        clearing?.cancel()
        clearing = nil
        guard let delay else { notice = nil; return }
        clearing = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { notice = nil }
        }
    }

    /// Reads the patch under the latest point, one read at a time: the loupe
    /// follows the pointer a read behind rather than queueing them.
    private func readLoupe() {
        guard reading == nil, let fraction = latest, let point = hover, let texture = texture(point) else { return }
        let radius = Self.patch / 2
        let x = min(max(Int(fraction.x * Double(texture.width)), 0), texture.width - 1)
        let y = min(max(Int(fraction.y * Double(texture.height)), 0), texture.height - 1)
        let region = MTLRegionMake2D(min(max(x - radius, 0), max(texture.width - Self.patch, 0)),
                                     min(max(y - radius, 0), max(texture.height - Self.patch, 0)),
                                     min(Self.patch, texture.width), min(Self.patch, texture.height))
        let source = SendableTexture(texture: texture)
        reading = Task { @MainActor in
            let values = await Self.read(source, region: region)
            reading = nil
            guard isActive, !isSampling else { return }
            if let values { loupe = Self.image(values, width: region.size.width, height: region.size.height) }
            if let latest, latest != fraction { readLoupe() }
        }
    }

    nonisolated private static func read(_ source: SendableTexture, region: MTLRegion) async -> [Float]? {
        try? await TextureReadback.floats(source.texture, region: region)
    }

    /// Linear Display P3 floats as an sRGB-encoded Display P3 image: what
    /// the photo's SDR rendition looks like at that spot.
    nonisolated static func image(_ values: [Float], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, values.count >= width * height * 4,
              let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 { bytes[pixel * 4 + channel] = encode(values[pixel * 4 + channel]) }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    nonisolated private static func encode(_ linear: Float) -> UInt8 {
        let v = min(max(linear.isFinite ? linear : 0, 0), 1)
        let e = v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055
        return UInt8((e * 255).rounded())
    }
}

nonisolated private struct SendableTexture: @unchecked Sendable {
    let texture: any MTLTexture
}

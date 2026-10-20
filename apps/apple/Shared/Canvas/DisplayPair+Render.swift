import CoreGraphics
import HyperDRRender

extension DisplayPair {
    /// Render's display pair (R3) as the compositor takes it, for both apps.
    /// Headrooms widen from Float to Double. A pair covering its whole
    /// `outputSize` is the preview (`region` nil); one with a smaller region
    /// is a detail layer at that place, in `outputSize` pixels, which the
    /// canvas's `CanvasTransform.imageSize` must match. The gain channel count
    /// follows from the gain texture's format, as Render writes it.
    init(_ pair: DisplayGainPair) {
        let whole = CGRect(x: 0, y: 0, width: pair.outputSize.width, height: pair.outputSize.height)
        self.init(base: pair.base, gain: pair.gain, coding: .log2,
                  baseOffset: pair.baseOffset, alternateOffset: pair.alternateOffset,
                  p3ToGain: pair.p3ToGain, gainToP3: pair.gainToP3,
                  baseHeadroom: Double(pair.baseHeadroom), alternateHeadroom: Double(pair.alternateHeadroom),
                  region: pair.region == whole ? nil : pair.region)
    }
}

extension DisplayMask {
    /// Render's effect mask (R6), placed by its region in `outputSize`.
    init(_ mask: RenderMask) {
        let width = Double(max(1, mask.outputSize.width)), height = Double(max(1, mask.outputSize.height))
        self.init(texture: mask.texture, rect: CGRect(x: mask.region.minX / width, y: mask.region.minY / height,
                                                      width: mask.region.width / width, height: mask.region.height / height))
    }
}

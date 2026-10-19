import SwiftUI

/// How much of the canvas's foot the floating things take, so none covers
/// another. The camera-support card, the busy chip and the export capsule sit
/// at the foot of the canvas; the zebra legend and the hint sit at the foot
/// of the visible photograph, which is the foot of the canvas when the photo
/// fills it. Each of the first group reports its height (with the gap under
/// it); the capsule rides above the card, and the legend and hint ride above
/// both.
struct CanvasBottomReserve: Equatable {
    /// The card or the busy chip: what the canvas is saying about the photo.
    var status: CGFloat = 0
    /// The export capsule, which the card lifts.
    var capsule: CGFloat = 0

    /// Everything that sits at the foot of the canvas, stacked.
    var total: CGFloat { status + capsule }

    /// The extra padding the legend or hint needs at the foot of the visible
    /// photograph so it clears the reserve: the part of the reserved band that
    /// reaches into the photograph, and a small gap when there is any.
    static func clearance(reserve: CGFloat, canvasHeight: CGFloat, visibleMaxY: CGFloat, gap: CGFloat = 8) -> CGFloat {
        guard reserve > 0 else { return 0 }
        let below = max(0, canvasHeight - visibleMaxY)
        let intrusion = max(0, reserve - below)
        return intrusion > 0 ? intrusion + gap : 0
    }
}

struct CanvasBottomReserveKey: PreferenceKey {
    static var defaultValue = CanvasBottomReserve()
    static func reduce(value: inout CanvasBottomReserve, nextValue: () -> CanvasBottomReserve) {
        let next = nextValue()
        value.status = max(value.status, next.status)
        value.capsule = max(value.capsule, next.capsule)
    }
}

/// Where the floating things ended up, in window coordinates, by name: the
/// geometry test reads it; nothing else does.
struct CanvasFloatingFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Tells the canvas how tall this is, with `gap` beneath it, as part of the
    /// foot's reserve; and where it is, under `name`.
    func reportsCanvasFoot(_ part: WritableKeyPath<CanvasBottomReserve, CGFloat>, gap: CGFloat, name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CanvasBottomReserveKey.self, value: {
                        var reserve = CanvasBottomReserve()
                        reserve[keyPath: part] = proxy.size.height + gap
                        return reserve
                    }())
                    .preference(key: CanvasFloatingFramesKey.self, value: [name: proxy.frame(in: .global)])
            }
        }
    }

    /// Reports where this is, under `name`, without taking part in the reserve.
    func reportsCanvasFrame(name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: CanvasFloatingFramesKey.self, value: [name: proxy.frame(in: .global)])
            }
        }
    }
}

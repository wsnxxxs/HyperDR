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
    /// The small "updating" chip in the bottom-right corner. It is out of the
    /// way of everything but what reaches its columns, so it counts only
    /// there (`lift(over:)`): a refresh that comes and goes must not move the
    /// legend while a slider is dragged.
    var chip: CGFloat = 0

    /// The card and the capsule, stacked: what always keeps the legend, the
    /// hint and the drop notice above it.
    var total: CGFloat { status + capsule }

    /// The foot's height for something at the canvas's foot that spans
    /// `columns`: the card and capsule, and the chip when it shares a column
    /// with it. `chip` is the chip's horizontal extent (nil: not showing).
    static func lift(_ reserve: CanvasBottomReserve, columns: ClosedRange<CGFloat>?, chip: ClosedRange<CGFloat>?) -> CGFloat {
        var height = reserve.total
        if reserve.chip > 0, let columns, let chip, columns.overlaps(chip) { height += reserve.chip }
        return height
    }

    /// The capsule's own lift: the card, and the chip when it shares a column.
    static func capsuleLift(_ reserve: CanvasBottomReserve, capsule: ClosedRange<CGFloat>?, chip: ClosedRange<CGFloat>?) -> CGFloat {
        var height = reserve.status
        if reserve.chip > 0, let capsule, let chip, capsule.overlaps(chip) { height += reserve.chip }
        return height
    }

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
        value.chip = max(value.chip, next.chip)
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

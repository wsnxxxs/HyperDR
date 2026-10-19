import SwiftUI

/// The compare divider over the canvas: a full-height line, a round handle,
/// and the labels of the two sides.
///
/// Lay it over the canvas, the same size. `imageFrame` is the whole
/// photograph in the overlay's coordinates (the ratio is across it);
/// `visibleRect` is the part of the canvas that shows the photograph, so the
/// line, the handle and the labels stay on what can be seen when the photo
/// is zoomed past the window.
///
/// - Drag the handle or anywhere within 12 pt of the line.
/// - With keyboard navigation on, the handle takes focus; ← → nudge by 5%.
/// - VoiceOver sees one adjustable "Comparison divider" with its percentage.
/// - Labels sit at the top corners of the visible photograph; one fades when
///   the divider comes within 72 pt of its edge. The right label may be
///   followed by an HDR badge.
public struct SplitOverlay: View {
    private let ratio: Double
    private let imageFrame: CGRect
    private let visibleRect: CGRect
    private let originalLabel: Text
    private let editedLabel: Text
    private let showsHDRBadge: Bool
    private let onDrag: (Double) -> Void
    private let onEditingChanged: (Bool) -> Void
    private let onNudge: (Double) -> Void
    private let forcedState: HandleState?

    @State private var bracket = EditingBracket()
    @State private var hovered = false
    @State private var dragging = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    public init(ratio: Double, imageFrame: CGRect, visibleRect: CGRect, originalLabel: Text, editedLabel: Text,
                showsHDRBadge: Bool, onDrag: @escaping (Double) -> Void,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }, onNudge: @escaping (Double) -> Void) {
        self.init(ratio: ratio, imageFrame: imageFrame, visibleRect: visibleRect, originalLabel: originalLabel,
                  editedLabel: editedLabel, showsHDRBadge: showsHDRBadge, onDrag: onDrag,
                  onEditingChanged: onEditingChanged, onNudge: onNudge, forcedState: nil)
    }

    /// `forcedState` shows a handle state without the pointer or the
    /// keyboard, for the gallery and its snapshots.
    init(ratio: Double, imageFrame: CGRect, visibleRect: CGRect, originalLabel: Text, editedLabel: Text,
         showsHDRBadge: Bool, onDrag: @escaping (Double) -> Void, onEditingChanged: @escaping (Bool) -> Void,
         onNudge: @escaping (Double) -> Void, forcedState: HandleState?) {
        self.ratio = ratio
        self.imageFrame = imageFrame
        self.visibleRect = visibleRect
        self.originalLabel = originalLabel
        self.editedLabel = editedLabel
        self.showsHDRBadge = showsHDRBadge
        self.onDrag = onDrag
        self.onEditingChanged = onEditingChanged
        self.onNudge = onNudge
        self.forcedState = forcedState
    }

    enum HandleState { case rest, hover, drag, focus }

    private var state: HandleState {
        if let forcedState { return forcedState }
        if dragging { return .drag }
        if focused { return .focus }
        return hovered ? .hover : .rest
    }

    public var body: some View {
        let visible = imageFrame.intersection(visibleRect)
        let dividerX = SplitGeometry.dividerX(ratio: ratio, in: imageFrame)
        Color.clear
            .overlay(alignment: .topLeading) {
                if !visible.isNull, visible.width > 0, visible.height > 0 {
                    content(visible: visible, dividerX: dividerX)
                        .frame(width: visible.width, height: visible.height)
                        .offset(x: visible.minX, y: visible.minY)
                }
            }
            .coordinateSpace(name: Self.space)
            .allowsHitTesting(isEnabled)
    }

    private static let space = "SplitOverlay"

    private func content(visible: CGRect, dividerX: CGFloat) -> some View {
        let local = dividerX - visible.minX
        let onScreen = local >= 0 && local <= visible.width
        return ZStack(alignment: .topLeading) {
            labels(visible: visible, dividerX: dividerX)
            if onScreen {
                line.frame(width: 3, height: visible.height).position(x: local, y: visible.height / 2)
                handle.position(x: local, y: visible.height / 2)
                hitArea
                    .frame(width: SplitGeometry.hitWidth, height: visible.height)
                    .position(x: local, y: visible.height / 2)
            }
        }
    }

    private var line: some View {
        ZStack {
            Rectangle().fill(Color.hdr.overlayShadow).frame(width: 3)
            Rectangle().fill(Color.hdr.overlayLineStrong).frame(width: 1)
        }
        .allowsHitTesting(false)
    }

    private var handle: some View {
        let big = state != .rest
        let diameter: CGFloat = big ? 32 : 28
        return Circle()
            .fill(Color.hdr.overlay)
            .overlay {
                Circle().strokeBorder(state == .drag ? Color.hdr.overlayInk : Color.hdr.overlayLine,
                                      lineWidth: state == .drag ? 1.5 : 1)
            }
            .overlay {
                Image(systemName: "chevron.left.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.hdr.overlayInk)
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                if state == .focus {
                    Circle().strokeBorder(Color.hdr.overlayInk, lineWidth: 2).padding(-6)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .hdrAnimation(Motion.fast, value: state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 24 pt wide, the photograph's full height; the pointer is a left-right
    /// resize, a drag moves the divider, arrows nudge it.
    private var hitArea: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(.rect)
            .onHover { hovered = $0 }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { drag in
                        guard isPrimaryPointerEvent else { return }
                        dragging = true
                        bracket.begin(onEditingChanged)
                        onDrag(SplitGeometry.ratio(forX: drag.location.x, in: imageFrame))
                    }
                    .onEnded { _ in finishDrag() }
            )
            .focusable(interactions: .activate)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                onNudge(press.key == .rightArrow ? SplitGeometry.nudgeStep : -SplitGeometry.nudgeStep)
                return .handled
            }
            .onDisappear { finishDrag() }
            .accessibilityElement()
            .accessibilityLabel(Text("design.split.divider", bundle: .module))
            .accessibilityValue(Text(verbatim: ratio.formatted(.percent.precision(.fractionLength(0)))))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onNudge(SplitGeometry.nudgeStep)
                case .decrement: onNudge(-SplitGeometry.nudgeStep)
                @unknown default: break
                }
            }
    }

    private func finishDrag() {
        dragging = false
        bracket.finish(onEditingChanged)
    }

    private func labels(visible: CGRect, dividerX: CGFloat) -> some View {
        ZStack {
            originalLabel
                .font(.hdr.caption)
                .foregroundStyle(Color.hdr.overlayInk)
                .hdrOverlayChip()
                .opacity(SplitGeometry.labelOpacity(.original, dividerX: dividerX, visible: visible))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 6) {
                editedLabel
                    .font(.hdr.caption)
                    .foregroundStyle(Color.hdr.overlayInk)
                    .hdrOverlayChip()
                if showsHDRBadge { HDRBadge() }
            }
            .opacity(SplitGeometry.labelOpacity(.edited, dividerX: dividerX, visible: visible))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(12)
        .hdrAnimation(Motion.fast, value: SplitGeometry.labelOpacity(.original, dividerX: dividerX, visible: visible))
        .hdrAnimation(Motion.fast, value: SplitGeometry.labelOpacity(.edited, dividerX: dividerX, visible: visible))
        .allowsHitTesting(false)
    }
}

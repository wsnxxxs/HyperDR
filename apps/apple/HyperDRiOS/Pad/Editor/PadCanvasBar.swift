import HyperDRDesign
import SwiftUI

/// The canvas bar (ipad-studio §3.2): a glass capsule under the photo with
/// the comparison (Adjusted, Split, Original), the zoom (Fit or the
/// percentage; a tap goes between fit and actual pixels) and the screen's HDR
/// headroom, which says how much brighter than SDR white this screen can show
/// right now. ⌥⌘1, ⌥⌘2 and ⌥⌘3 pick the views; ⌘0 the zoom.
struct PadCanvasBar: View {
    @Binding var comparison: Comparison
    /// There is an original to compare with (or one is on its way).
    let canCompare: Bool
    /// The frame previews the export as a whole: no split there.
    let allowsSplit: Bool
    /// Nil hides the zoom (the frame always fits).
    let zoom: Zoom?
    let onZoom: () -> Void
    let headroom: HeadroomSnapshot
    /// The photo on screen carries HDR.
    let showsHDR: Bool

    @Namespace private var highlight
    @State private var explainingHeadroom = false

    /// The canvas's zoom as the bar says it.
    enum Zoom: Equatable {
        case fit
        case percent(Int)
    }

    var body: some View {
        GlassEffectContainer(spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                HStack(spacing: 2) {
                    view(.edited, symbol: "wand.and.sparkles", title: Text("ios.view.edited"), key: "1")
                    view(.split, symbol: "rectangle.split.2x1", title: Text("ios.view.split"), key: "2")
                        .disabled(!allowsSplit || !canCompare)
                    view(.original, symbol: "photo", title: Text("ios.view.original"), key: "3")
                        .disabled(!canCompare)
                }
                .padding(4)
                .glassEffect(.regular, in: .capsule)
                if let zoom {
                    Button(action: onZoom) {
                        Group {
                            switch zoom {
                            case .fit: Text("ipad.zoom.fit")
                            case .percent(let value): Text(verbatim: "\(value)%")
                            }
                        }
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .contentTransition(.numericText())
                        .frame(minWidth: 52)
                        .padding(.horizontal, Space.s3)
                        .frame(height: 44)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .keyboardShortcut("0", modifiers: .command)
                    .accessibilityLabel(Text("ipad.zoom"))
                    .transition(.opacity.combined(with: .scale(0.9)))
                }
                headroomButton
            }
        }
        .animation(.smooth(duration: 0.25), value: comparison)
        .animation(.smooth(duration: 0.25), value: zoom == nil)
        .sensoryFeedback(.selection, trigger: comparison)
    }

    private func view(_ mode: Comparison, symbol: String, title: Text, key: Character) -> some View {
        let isCurrent = comparison == mode
        return Button { comparison = mode } label: {
            Label { title } icon: { Image(systemName: symbol) }
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                .padding(.horizontal, Space.s3)
                .frame(height: 36)
                .background {
                    if isCurrent {
                        Capsule().fill(Color.white.opacity(0.16)).matchedGeometryEffect(id: "view", in: highlight)
                    }
                }
                .contentShape(.capsule)
                .contentShape(.hoverEffect, .capsule)
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// "3.1×" with the sun lit while the screen shows HDR; "SDR" on a screen
    /// with no headroom. A tap explains it.
    private var headroomButton: some View {
        let hasHeadroom = headroom.potential > 1.01
        let lit = showsHDR && headroom.current > 1.01
        return Button { explainingHeadroom = true } label: {
            HStack(spacing: 5) {
                Image(systemName: lit ? "sun.max.fill" : "sun.max")
                    .foregroundStyle(lit ? Color.hdr.amber : Color.secondary)
                if hasHeadroom {
                    Text(verbatim: EditorCanvas.headroom(headroom.current))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                } else {
                    Text(verbatim: "SDR")
                }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, Space.s3)
            .frame(height: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .popover(isPresented: $explainingHeadroom) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Label { Text("ipad.headroom.title") } icon: { Image(systemName: "sun.max.fill").foregroundStyle(Color.hdr.amber) }
                    .font(.headline)
                if hasHeadroom {
                    Text("ios.display.edr \(EditorCanvas.headroom(headroom.current)) \(EditorCanvas.headroom(headroom.potential))")
                        .font(.subheadline)
                    Text("ipad.headroom.note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("ipad.headroom.none")
                        .font(.subheadline)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 300, alignment: .leading)
            .padding(Space.s4)
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel(Text("ipad.headroom.title"))
        .accessibilityValue(Text(verbatim: hasHeadroom ? EditorCanvas.headroom(headroom.current) : "SDR"))
    }
}

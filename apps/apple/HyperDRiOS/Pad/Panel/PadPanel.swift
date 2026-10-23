import HyperDRDesign
import SwiftUI

/// The Studio panel (ipad-studio §3.3): one floating glass panel holding the
/// tool rail and the current tool. Standing on the right, the rail runs down
/// its outer edge and the histogram heads the tool; lying along the foot, the
/// rail runs across its top. Collapsed, only the rail is left. Each tool opens
/// scrolled to its top. Standing, the photo's facts close the panel.
struct PadPanel<Rail: View, Histogram: View, Header: View, Content: View, Footer: View>: View {
    let placement: PadLayout.Placement
    let expanded: Bool
    /// The tool shown, so switching tools starts the scroll afresh.
    let tool: PadTool
    @ViewBuilder let rail: (Axis) -> Rail
    /// Standing only: lying, the header carries a small one.
    @ViewBuilder let histogram: Histogram
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    /// Standing only, under the tool.
    @ViewBuilder let footer: Footer

    var body: some View {
        Group {
            switch placement {
            case .side: side
            case .bottom: bottom
            }
        }
        .padPanelSurface()
        .animation(.smooth(duration: 0.3), value: expanded)
    }

    private var side: some View {
        HStack(spacing: 0) {
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    histogram
                        .frame(height: 92)
                        .padding(.horizontal, PadMetrics.inset)
                        .padding(.top, PadMetrics.inset)
                    header
                        .padding(.horizontal, PadMetrics.inset + 2)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    scroll
                    footer
                        .padding(.horizontal, PadMetrics.inset)
                        .padding(.bottom, PadMetrics.inset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 18)
            }
            ScrollView(.vertical) {
                rail(.vertical)
                    .padding(.top, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .frame(width: PadMetrics.railWidth)
        }
    }

    private var bottom: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                rail(.horizontal)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.center, for: .alignment)
            .frame(height: PadMetrics.railHeight)
            if expanded {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 18)
                header
                    .padding(.horizontal, PadMetrics.inset + 2)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                scroll
                    .transition(.opacity)
            }
        }
    }

    private var scroll: some View {
        ScrollView {
            content
                .padding(.horizontal, PadMetrics.inset)
                .padding(.top, 2)
                .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .id(tool)
    }
}

/// The current tool's title row: its name (and for HDR what it touches), the
/// small histogram when the panel lies along the foot, HDR's switch, and the
/// tool's reset.
struct PadToolHeader: View {
    let title: Text
    var subtitle: Text? = nil
    /// HDR's on/off switch.
    var power: Binding<Bool>? = nil
    var canReset = false
    var onReset: (() -> Void)? = nil
    var histogram: AnyView? = nil

    var body: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    subtitle
                        .font(.caption)
                        .foregroundStyle(Color.hdr.amber)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: Space.s2)
            if let histogram {
                histogram.frame(width: 156, height: 38)
            }
            if let power {
                Toggle(isOn: power) { title }
                    .labelsHidden()
                    .tint(Color.hdr.amber)
                    .sensoryFeedback(.impact(weight: .light), trigger: power.wrappedValue)
            }
            if let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(!canReset)
                .opacity(canReset ? 1 : 0.35)
                .accessibilityLabel(AdjustmentText.command(.resetGroup))
            }
        }
        .frame(minHeight: 40)
    }
}

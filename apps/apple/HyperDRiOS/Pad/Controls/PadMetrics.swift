import HyperDRDesign
import SwiftUI

/// Sizes and surfaces of the iPad Studio (docs/design/ipad-studio.md): one
/// row height for every control, so sliders, switches, segments and menus
/// line up in the panel's columns.
enum PadMetrics {
    /// Every control row.
    static let row: CGFloat = 44
    static let rowRadius: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    /// Between a panel's edge and its controls.
    static let inset: CGFloat = 14
    /// Between the window's edge and a floating panel.
    static let margin: CGFloat = 10
    static let panelRadius: CGFloat = 28
    /// The tool rail: its width standing on the side, its height lying at the foot.
    static let railWidth: CGFloat = 76
    static let railHeight: CGFloat = 74
    /// The strip under the canvas that holds the canvas bar.
    static let canvasBarStrip: CGFloat = 68
}

extension View {
    /// The fill of a control row: a faint well on the panel's glass.
    func padRow(active: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: PadMetrics.rowRadius, style: .continuous)
            .fill(Color.white.opacity(active ? 0.11 : 0.06)))
    }

    /// A floating Studio panel: glass in a large rounded rectangle.
    func padPanelSurface(cornerRadius: CGFloat = PadMetrics.panelRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// A titled run of controls inside a tool.
struct PadSection<Content: View>: View {
    let title: Text?
    @ViewBuilder let content: Content

    init(_ title: Text? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PadMetrics.rowSpacing) {
            if let title {
                title
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .padding(.top, 2)
            }
            content
        }
    }
}

/// Lays rows out in one column on the side panel and two under the canvas.
struct PadRows<Content: View>: View {
    let columns: Int
    @ViewBuilder let content: Content

    init(columns: Int, @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.content = content()
    }

    var body: some View {
        if columns > 1 {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PadMetrics.rowSpacing), count: columns),
                      alignment: .leading, spacing: PadMetrics.rowSpacing) {
                content
            }
        } else {
            VStack(alignment: .leading, spacing: PadMetrics.rowSpacing) { content }
        }
    }
}

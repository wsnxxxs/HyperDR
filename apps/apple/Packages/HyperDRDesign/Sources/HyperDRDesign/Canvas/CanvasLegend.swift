import SwiftUI

/// One line of a `CanvasLegend`.
public enum CanvasLegendRow {
    /// Highlights that will be clipped on export.
    case highlightZebra
    /// Shadows that are pure black in the SDR version.
    case shadowZebra
    /// The area a control acts on (the mask), named by the control.
    case mask(controlName: Text)
}

/// The dark card in a corner of the photograph that says what the overlay
/// colours on it mean: one row for each overlay on, a swatch and a short line.
public struct CanvasLegend: View {
    private let rows: [CanvasLegendRow]

    public init(rows: [CanvasLegendRow]) { self.rows = rows }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    swatch(for: row)
                    label(for: row)
                        .font(.hdr.caption)
                        .foregroundStyle(Color.hdr.overlayInk)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.hdr.overlay, in: .rect(cornerRadius: Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.overlayLine) }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func swatch(for row: CanvasLegendRow) -> some View {
        switch row {
        case .highlightZebra: StripeSwatch(color: CanvasOverlayStyle.highlightColor)
        case .shadowZebra: StripeSwatch(color: CanvasOverlayStyle.shadowColor)
        case .mask:
            RoundedRectangle(cornerRadius: 2)
                .fill(CanvasOverlayStyle.maskColor.opacity(0.85))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func label(for row: CanvasLegendRow) -> some View {
        switch row {
        case .highlightZebra: Text("design.legend.highlights", bundle: .module)
        case .shadowZebra: Text("design.legend.shadows", bundle: .module)
        case .mask(let name): Text("design.legend.mask \(name)", bundle: .module)
        }
    }
}

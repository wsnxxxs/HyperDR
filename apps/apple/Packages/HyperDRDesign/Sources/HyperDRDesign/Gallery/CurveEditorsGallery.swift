import SwiftUI

/// The curve editors on made-up values (adjust-tools): the luminance curve
/// with its amber HDR segment, a curve with the SDR segment only, a colour
/// channel's, and the parametric curve with its zone boundaries. For
/// previews and the design record; nothing here is wired to a photo.
public struct CurveEditorsGallery: View {
    @State private var luma = [0.0, 0, 0.3, 0.2, 0.7, 0.8, 1, 1, 2.2, 2.9]
    @State private var red = [0.0, 0, 0.5, 0.58, 1, 1]
    @State private var amounts = [20.0, -15, 35, -40]
    @State private var splits = [25.0, 50, 75]
    private let style: AdjustmentControlStyle

    public init(style: AdjustmentControlStyle = .pointer) { self.style = style }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            caption("Luminance · Both — range 3 stops")
            ToneCurveEditor(coordinates: luma, style: style, hdrStops: 3, marker: 0.45,
                            write: { luma = $0 })
                .frame(maxWidth: style == .touch ? 380 : 292)
            caption("Red — SDR segment only")
            ToneCurveEditor(coordinates: red, style: style, hdrStops: nil, marker: nil,
                            tint: ToneCurveTint(sdr: .hdr.histogramRed), write: { red = $0 }, onEditingChanged: { _ in })
                .frame(maxWidth: style == .touch ? 320 : 240)
            caption("Parametric")
            ParametricCurveEditor(preview: ParametricCurvePreview(amounts: amounts.reversed(), splits: splits), style: style,
                                  moveSplit: { index, percent in splits = ParametricCurvePreview.moved(splits, index: index, to: percent) },
                                  onEditingChanged: { _, _ in })
                .frame(maxWidth: style == .touch ? 320 : 240)
        }
        .padding(Space.s4)
        .background(Color.hdr.surfacePanel)
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text).font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
    }
}

#Preview("Curve editors") {
    CurveEditorsGallery().frame(width: 340)
}

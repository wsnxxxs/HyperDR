import SwiftUI

/// The colour mixer (and, below it, the colour grading) on made-up values, in
/// the style given: for previews and the design record. The sliders are the
/// ordinary ones on a local number per parameter id.
public struct ColorSectionsGallery: View {
    @State private var values: [String: Double]
    private let style: AdjustmentControlStyle
    private let arrangement: Int
    private let showsGrading: Bool

    /// `arrangement` 0 reads the mixer by attribute, 1 by colour; `showsGrading` swaps the mixer for the grading.
    public init(style: AdjustmentControlStyle = .pointer, arrangement: Int = 0, showsGrading: Bool = false) {
        self.style = style
        self.arrangement = arrangement
        self.showsGrading = showsGrading
        _values = State(initialValue: showsGrading
            ? ["grade.shadows.hue": 215, "grade.shadows.saturation": 55, "grade.highlights.hue": 38, "grade.highlights.saturation": 40,
               "grade.highlights.luminance": 12, "grade.blending": 50]
            : ["hsl.red.hue": -20, "hsl.orange.saturation": 30, "hsl.blue.luminance": -45, "hsl.green.hue": 12])
    }

    private static let spec = ParameterSpec(range: -100...100, step: 1, defaultValue: 0, origin: 0,
                                            format: .signed(fractionDigits: 0))

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s5) {
            if showsGrading { grading } else { mixer }
        }
        .padding(Space.s4)
        .background(Color.hdr.surfacePanel)
    }

    private func slider(_ id: String, _ title: Text, spec: ParameterSpec? = nil, gradient: [Color]? = nil) -> some View {
        let value = Binding(get: { values[id] ?? 0 }, set: { values[id] = $0 })
        let spec = spec ?? Self.spec
        return Group {
            if style == .touch {
                TouchParameterSlider(title, value: value, spec: spec)
            } else {
                ParameterSlider(title, value: value, spec: spec)
            }
        }
        .environment(\.sliderTrackGradient, gradient)
    }

    private var grading: some View {
        ColorGradingLayout(style: style, showsTitle: true,
                           colour: { zone in (values[zone.hueID] ?? 0, values[zone.saturationID] ?? 0, values[zone.luminanceID] ?? 0) },
                           isChanged: { (values[$0] ?? 0) != 0 },
                           writeWheel: { zone, hue, saturation in
            if let hue { values[zone.hueID] = hue.rounded() }
            values[zone.saturationID] = saturation.rounded()
        }, resetWheel: { zone in values[zone.hueID] = 0; values[zone.saturationID] = 0 },
                           wheelEditing: { _, _ in }, resetAll: { values = [:] }) { id, title, gradient in
            let wide = id.hasSuffix(".hue")
            let spec = wide ? ParameterSpec(range: 0...360, step: 1, defaultValue: 0, origin: 0, format: .number(fractionDigits: 0))
                : id.hasSuffix(".saturation") ? ParameterSpec(range: 0...100, step: 1, defaultValue: 0, origin: 0, format: .number(fractionDigits: 0))
                : Self.spec
            slider(id, title ?? Text(verbatim: id.hasSuffix("blending") ? "Blending" : "Balance"), spec: spec, gradient: gradient)
        }
    }

    private var mixer: some View {
        VStack {
            ColorMixerLayout(style: style, showsTitle: true, isChanged: { (values[$0] ?? 0) != 0 },
                             resetAll: { values = [:] }, initialArrangement: arrangement == 0 ? .attribute : .band) { id, title, _, gradient in
                slider(id, title, gradient: gradient)
            }
        }
    }
}

#Preview("Colour sections") {
    ColorSectionsGallery().frame(width: 340)
}

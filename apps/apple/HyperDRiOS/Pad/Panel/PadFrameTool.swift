import HyperDRDesign
import SwiftUI

/// The Frame tool (ipad-studio §3.4): the styles in miniature, laid out by
/// the engine around this photo on the chosen paper; the paper; what the
/// caption says and the signature; the print's shadow; and the framed size.
/// The frame is the export's: the canvas shows it around the photo while
/// this tool is open, and every export carries it while it is on.
struct PadFrameTool: View {
    @Binding var settings: FrameSettings
    /// The photo's oriented size, which shapes the miniatures.
    let photoSize: (width: Int, height: Int)?
    /// The frame is on but its style does not fit this photo.
    let misfits: Bool
    /// The framed export's size at full size, when the frame is on.
    let output: (width: Int, height: Int)?
    var columns = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PadSection(Text("ios.frame.style")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: PadMetrics.rowSpacing)],
                          alignment: .leading, spacing: 12) {
                    FrameStyleTile(style: nil, settings: settings, photoSize: photoSize) { choose(nil) }
                    ForEach(FrameStyle.allCases) { style in
                        FrameStyleTile(style: style, settings: settings, photoSize: photoSize) { choose(style) }
                    }
                }
                if settings.isEnabled && misfits {
                    FrameMisfitNote(alignment: .leading)
                }
            }
            Group {
                PadSection(Text("ios.frame.tone")) {
                    FrameTones(settings: $settings)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: PadMetrics.row + 8, alignment: .leading)
                        .padRow()
                }
                PadSection(Text("ios.frame.caption")) {
                    if settings.style.hasCaption {
                        PadRows(columns: columns) {
                            PadToggleRow(title: Text("ios.frame.text.exposure"), isOn: $settings.showsExposure,
                                         symbol: "camera.aperture")
                            PadToggleRow(title: Text("ios.frame.text.camera"), isOn: $settings.showsCamera,
                                         symbol: "camera")
                            PadToggleRow(title: Text("ios.frame.text.date"), isOn: $settings.showsDate,
                                         symbol: "calendar")
                            PadToggleRow(title: Text("ios.frame.shadow"), isOn: $settings.showsShadow,
                                         symbol: "shadow")
                                .disabled(settings.style.geometry.shadow == nil)
                        }
                        signature
                    } else {
                        PadToggleRow(title: Text("ios.frame.shadow"), isOn: $settings.showsShadow, symbol: "shadow")
                            .disabled(settings.style.geometry.shadow == nil)
                    }
                }
                if settings.style.hasCaption {
                    PadSection(Text("ios.frame.font")) {
                        PadFrameTypefaceRows(settings: $settings)
                    }
                }
            }
            .disabled(!settings.isEnabled)
            .opacity(settings.isEnabled ? 1 : 0.45)
            if let output, settings.isEnabled {
                HStack {
                    Text("ios.frame.output").font(.subheadline)
                    Spacer()
                    Text(verbatim: "\(output.width) × \(output.height)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, PadMetrics.inset)
                .frame(height: PadMetrics.row)
                .padRow()
            }
        }
        .tint(Color.hdr.accent)
    }

    private var signature: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "signature")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            TextField(text: $settings.signature, prompt: Text("ios.frame.signature.prompt")) {
                Text("ios.frame.signature")
            }
            .font(.subheadline)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
        }
        .padding(.horizontal, PadMetrics.inset)
        .frame(height: PadMetrics.row)
        .padRow()
    }

    private func choose(_ style: FrameStyle?) {
        withAnimation(.smooth(duration: 0.3)) {
            if let style {
                settings.style = style
                settings.isEnabled = true
            } else {
                settings.isEnabled = false
            }
        }
    }
}

import SwiftUI
import HyperDRDesign

extension FrameColor {
    /// The frame's colours are Display P3, as the engine reads the background.
    var color: Color { Color(.displayP3, red: red, green: green, blue: blue) }
}

/// The caption band under the photograph. The preview draws it at screen size;
/// export renders this same view at one point per pixel into the overlay the
/// engine composites, so both carry identical typography.
struct FrameCaptionView: View {
    let caption: FrameCaption
    let settings: FrameSettings
    let layout: FramePixelLayout
    /// Points per engine pixel.
    let scale: CGFloat

    private var reference: CGFloat { CGFloat(layout.referenceEdge) * scale }

    var body: some View {
        let band = CGSize(width: CGFloat(layout.caption.width) * scale,
                          height: CGFloat(layout.caption.height) * scale)
        let place = placement(in: band.height)
        ZStack(alignment: place.alignment) {
            column(caption.center, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            column(caption.leading, alignment: .leading)
                .padding(.leading, CGFloat(layout.photo.x) * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            column(caption.trailing, alignment: .trailing)
                .padding(.trailing, CGFloat(layout.width - layout.photo.x - layout.photo.width) * scale)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: band.width, height: place.height, alignment: place.alignment)
        .padding(.top, place.offset)
        .frame(width: band.width, height: band.height, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    /// Where the text sits inside the band.
    private struct Placement {
        var offset: CGFloat
        var height: CGFloat
        var alignment: Alignment
    }

    private func placement(in height: CGFloat) -> Placement {
        switch caption.placement {
        case .middle(let abovePaperMargin):
            let margin = abovePaperMargin ? settings.style.geometry.bottom * reference : 0
            return Placement(offset: 0, height: max(0, height - margin), alignment: .center)
        case .top(let fraction):
            let offset = fraction * reference
            return Placement(offset: offset, height: max(0, height - offset), alignment: .top)
        }
    }

    private func column(_ lines: [FrameCaptionLine], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(lines) { line in
                Text(verbatim: line.text)
                    .font(font(line))
                    .tracking(line.tracking * line.size * reference)
                    .foregroundStyle((line.ink == .primary ? settings.tone.primaryInk : settings.tone.secondaryInk).color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.top, line.gap * reference)
            }
        }
    }

    private func font(_ line: FrameCaptionLine) -> Font {
        let size = line.size * reference
        switch line.face {
        case .text: return .system(size: size).monospacedDigit()
        case .semibold: return .system(size: size, weight: .semibold)
        // New York italic: a signature set in type rather than a script face.
        case .signature: return .system(size: size, design: .serif).italic()
        }
    }
}

/// A photograph on its frame, fitted to the space offered. `photo` fills the
/// print's rect -- in the app the live EDR canvas -- so the frame, drawn here
/// in SDR, sits at reference white beside the photograph's real highlights.
struct FramedPhoto<Photo: View>: View {
    let layout: FramePixelLayout
    let settings: FrameSettings
    let caption: FrameCaption
    @ViewBuilder let photo: () -> Photo

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / CGFloat(layout.width), proxy.size.height / CGFloat(layout.height))
            let canvas = CGSize(width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
            let print = CGRect(x: CGFloat(layout.photo.x) * scale, y: CGFloat(layout.photo.y) * scale,
                               width: CGFloat(layout.photo.width) * scale, height: CGFloat(layout.photo.height) * scale)
            let reference = CGFloat(layout.referenceEdge) * scale
            let shadow = settings.isEnabled && settings.showsShadow ? settings.style.geometry.shadow : nil
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(settings.isEnabled ? settings.tone.background.color : Color.clear)
                // Under the canvas: a placeholder until a frame arrives, and the
                // print's shadow. Sigma maps to the shadow radius.
                Rectangle()
                    .fill(Color.hdr.previewBackdrop)
                    .shadow(color: .black.opacity(shadow?.opacity ?? 0), radius: (shadow?.blur ?? 0) * reference,
                            y: (shadow?.offset ?? 0) * reference)
                    .frame(width: print.width, height: print.height)
                    .position(x: print.midX, y: print.midY)
                photo()
                    .frame(width: print.width, height: print.height)
                    .position(x: print.midX, y: print.midY)
                if settings.isEnabled, layout.caption.height > 0 {
                    FrameCaptionView(caption: caption, settings: settings, layout: layout, scale: scale)
                        .frame(width: canvas.width, height: CGFloat(layout.caption.height) * scale)
                        .position(x: canvas.width / 2,
                                  y: (CGFloat(layout.caption.y) + CGFloat(layout.caption.height) / 2) * scale)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .hdrAnimation(value: settings)
        }
    }
}

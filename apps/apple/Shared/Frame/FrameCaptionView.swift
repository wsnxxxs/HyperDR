import SwiftUI
import HyperDRDesign

extension FrameColor {
    /// The frame's colours are Display P3, as the engine reads the background.
    var color: Color { Color(.displayP3, red: red, green: green, blue: blue) }
}

enum FrameCaptionSpace { static let name = "FrameCaptionBand" }

private struct FrameLineFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
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
    /// Told where each line was laid out, by line id, in the band's own
    /// coordinates; tests use it to check that no line is cut off.
    var onLineFrames: (([Int: CGRect]) -> Void)? = nil

    private var reference: CGFloat { CGFloat(layout.referenceEdge) * scale }

    var body: some View {
        let band = CGSize(width: CGFloat(layout.caption.width) * scale,
                          height: CGFloat(layout.caption.height) * scale)
        let place = placement(in: band.height)
        let margins = settings.style.geometry.applying(layout.variant)
        // Long text shrinks to 70% of its size, then is cut with an ellipsis,
        // on one line: a column never grows past its share of the band.
        let centerWidth = max(0, band.width - CGFloat(margins.left + margins.right) * reference)
        let leftPad = CGFloat(layout.photo.x) * scale
        let rightPad = CGFloat(layout.width - layout.photo.x - layout.photo.width) * scale
        ZStack(alignment: place.alignment) {
            if !caption.center.isEmpty {
                column(caption.center, alignment: .center)
                    .frame(maxWidth: centerWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            if !caption.leading.isEmpty || !caption.trailing.isEmpty {
                // Two columns keep a gap between them; the right one takes at
                // most 40% of the card, the left one the rest.
                HStack(alignment: place.alignment.vertical, spacing: 0.02 * reference) {
                    if caption.leading.isEmpty {
                        Spacer(minLength: 0)
                    } else {
                        column(caption.leading, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !caption.trailing.isEmpty {
                        column(caption.trailing, alignment: .trailing)
                            .frame(maxWidth: band.width * 0.4, alignment: .trailing)
                    }
                }
                .padding(.leading, leftPad)
                .padding(.trailing, rightPad)
            }
        }
        .frame(width: band.width, height: place.height, alignment: place.alignment)
        .padding(.top, place.offset)
        .frame(width: band.width, height: band.height, alignment: .top)
        .coordinateSpace(name: FrameCaptionSpace.name)
        .onPreferenceChange(FrameLineFramesKey.self) { onLineFrames?($0) }
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
            let margin = abovePaperMargin
                ? settings.style.geometry.applying(layout.variant).bottom * reference : 0
            return Placement(offset: 0, height: max(0, height - margin), alignment: .center)
        case .top(let fraction):
            let offset = fraction * reference
            return Placement(offset: offset, height: max(0, height - offset), alignment: .top)
        }
    }

    private func column(_ lines: [FrameCaptionLine], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(lines) { line in
                // Text that fits is set at its size, exactly; only text over the
                // column's width shrinks (to 70%), then is cut with an ellipsis.
                let text = Text(verbatim: line.text)
                    .font(font(line))
                    .tracking(line.tracking * line.size * reference)
                    .foregroundStyle((line.ink == .primary ? settings.tone.primaryInk : settings.tone.secondaryInk).color)
                    .lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    text.fixedSize()
                    text.minimumScaleFactor(0.7)
                }
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: FrameLineFramesKey.self,
                                                   value: [line.id: proxy.frame(in: .named(FrameCaptionSpace.name))])
                        }
                    }
                    .padding(.top, line.gap * reference)
            }
        }
    }

    private func font(_ line: FrameCaptionLine) -> Font {
        let size = line.size * reference
        switch line.face {
        case .text: return settings.textFace.font(size: size).monospacedDigit()
        case .semibold: return settings.textFace.font(size: size, weight: .semibold)
        case .signature:
            // A system design is set in italic (New York italic by default: a
            // signature in type rather than a script face); a named family
            // as it is, since it may be a script already.
            let font = settings.signatureFace.font(size: size)
            return settings.signatureFace.familyName == nil ? font.italic() : font
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

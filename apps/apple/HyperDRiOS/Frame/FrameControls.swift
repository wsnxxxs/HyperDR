import HyperDRDesign
import SwiftUI

/// The frame's controls (M3 frame sheet, on touch): no frame or one of the
/// five styles, the paper tone, and the caption and print shadow behind a
/// Caption button. The frame is the export's: choosing one shows it around
/// the photo on the canvas and every export carries it.
///
/// - `FrameDock` sits in the iPhone's bottom bar (or its standing bar in
///   landscape) and the narrow iPad's bottom panel.
/// - `FramePanel` is the iPad inspector's Frame tab, everything in one column.
struct FrameDock: View {
    @Binding var settings: FrameSettings
    /// The photo's oriented size, which shapes the miniatures.
    let photoSize: (width: Int, height: Int)?
    /// The frame is on but its style does not fit this photo.
    let misfits: Bool
    var axis: Axis = .horizontal
    var large = false
    @State private var showingCaption = false

    var body: some View {
        let stack = axis == .horizontal ? AnyLayout(VStackLayout(spacing: large ? Space.s4 : Space.s3))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s3))
        stack {
            if settings.isEnabled && misfits {
                FrameMisfitNote().frame(maxWidth: .infinity)
            }
            ScrollView(axis == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
                let tiles = axis == .horizontal ? AnyLayout(HStackLayout(spacing: Space.s3))
                    : AnyLayout(VStackLayout(spacing: Space.s2))
                tiles {
                    FrameStyleTile(style: nil, settings: settings, photoSize: photoSize) { choose(nil) }
                    ForEach(FrameStyle.allCases) { style in
                        FrameStyleTile(style: style, settings: settings, photoSize: photoSize) { choose(style) }
                    }
                }
                .padding(.horizontal, Space.s4)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .frame(maxHeight: axis == .vertical ? .infinity : nil)
            HStack(spacing: Space.s2) {
                FrameTones(settings: $settings)
                Spacer(minLength: Space.s2)
                Button { showingCaption = true } label: {
                    Label("ios.frame.caption", systemImage: "text.below.photo")
                        .font(.subheadline.weight(.medium))
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(Text("ios.frame.caption"))
            }
            .padding(.horizontal, Space.s4)
            .disabled(!settings.isEnabled)
            .opacity(settings.isEnabled ? 1 : 0.4)
        }
        .sheet(isPresented: $showingCaption) {
            NavigationStack {
                Form { FrameCaptionSections(settings: $settings) }
                    .tint(Color.hdr.accent)
                    .navigationTitle(Text("ios.frame.caption"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) { showingCaption = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
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

/// The iPad inspector's Frame tab.
struct FramePanel: View {
    @Binding var settings: FrameSettings
    let photoSize: (width: Int, height: Int)?
    let misfits: Bool
    /// The framed export's size at full size, when the frame is on.
    let output: (width: Int, height: Int)?

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: Space.s3)], spacing: Space.s3) {
                    FrameStyleTile(style: nil, settings: settings, photoSize: photoSize) { choose(nil) }
                    ForEach(FrameStyle.allCases) { style in
                        FrameStyleTile(style: style, settings: settings, photoSize: photoSize) { choose(style) }
                    }
                }
                .padding(.vertical, Space.s2)
            } header: {
                Text("ios.frame.style")
            } footer: {
                if settings.isEnabled && misfits { FrameMisfitNote(alignment: .leading) }
            }
            Section {
                FrameTones(settings: $settings)
            } header: {
                Text("ios.frame.tone")
            }
            .disabled(!settings.isEnabled)
            FrameCaptionSections(settings: $settings)
                .disabled(!settings.isEnabled)
            Section {
                Text("ios.frame.sdrNote").font(.footnote).foregroundStyle(.secondary)
                if let output {
                    LabeledContent {
                        Text(verbatim: "\(output.width) × \(output.height)").monospacedDigit()
                    } label: {
                        Text("ios.frame.output")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tint(Color.hdr.accent)
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

/// The caption's lines, the signature and the print shadow.
struct FrameCaptionSections: View {
    @Binding var settings: FrameSettings

    var body: some View {
        Section {
            if settings.style.hasCaption {
                Toggle("ios.frame.text.exposure", isOn: $settings.showsExposure)
                Toggle("ios.frame.text.camera", isOn: $settings.showsCamera)
                Toggle("ios.frame.text.date", isOn: $settings.showsDate)
                TextField(text: $settings.signature, prompt: Text("ios.frame.signature.prompt")) {
                    Text("ios.frame.signature")
                }
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
            } else {
                Text("ios.frame.text.none").foregroundStyle(.secondary)
            }
        } header: {
            Text("ios.frame.caption")
        }
        Section {
            Toggle("ios.frame.shadow", isOn: $settings.showsShadow)
                .disabled(settings.style.geometry.shadow == nil)
        }
    }
}

/// Why the chosen style is not drawn: the engine refuses it for this photo.
struct FrameMisfitNote: View {
    var alignment: TextAlignment = .center

    var body: some View {
        Label("ios.frame.misfit", systemImage: "exclamationmark.triangle")
            .foregroundStyle(Color.hdr.warn)
            .font(.footnote)
            .multilineTextAlignment(alignment)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The five paper tones.
struct FrameTones: View {
    @Binding var settings: FrameSettings

    var body: some View {
        HStack(spacing: Space.s2) {
            ForEach(FrameTone.allCases) { tone in
                let selected = settings.tone == tone
                Button { withAnimation(.smooth(duration: 0.2)) { settings.tone = tone } } label: {
                    Circle()
                        .fill(tone.background.color)
                        .overlay { Circle().strokeBorder(.white.opacity(0.18)) }
                        .frame(width: 26, height: 26)
                        .padding(4)
                        .overlay { if selected { Circle().strokeBorder(Color.white, lineWidth: 2) } }
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tone.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A style in miniature, laid out by the engine around this photo on the
/// chosen paper; `style == nil` is "No Frame".
struct FrameStyleTile: View {
    let style: FrameStyle?
    let settings: FrameSettings
    let photoSize: (width: Int, height: Int)?
    let action: () -> Void

    private var selected: Bool { style == nil ? !settings.isEnabled : settings.isEnabled && settings.style == style }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                miniature
                    .frame(width: 56, height: 68)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? Color.white : Color.white.opacity(0.1), lineWidth: selected ? 2 : 1)
                    }
                Group {
                    if let style { Text(style.title) } else { Text("ios.frame.none") }
                }
                .font(.caption2.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .lineLimit(1)
            }
            .frame(width: 72)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var miniature: some View {
        if let style {
            let layout = FrameLayouts.miniature(style, width: photoSize?.width, height: photoSize?.height)
            let tone = settings.tone
            Canvas { context, size in
                guard let layout else { return }
                let inset = size.width * 0.12
                let room = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
                let scale = min(room.width / CGFloat(layout.width), room.height / CGFloat(layout.height))
                let card = CGRect(x: (size.width - CGFloat(layout.width) * scale) / 2,
                                  y: (size.height - CGFloat(layout.height) * scale) / 2,
                                  width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
                context.fill(Path(card), with: .color(tone.background.color))
                let print = CGRect(x: card.minX + CGFloat(layout.photo.x) * scale,
                                   y: card.minY + CGFloat(layout.photo.y) * scale,
                                   width: CGFloat(layout.photo.width) * scale,
                                   height: CGFloat(layout.photo.height) * scale)
                context.fill(Path(print), with: .linearGradient(
                    Gradient(colors: [Color(white: 0.62), Color(white: 0.38)]),
                    startPoint: CGPoint(x: print.minX, y: print.minY), endPoint: CGPoint(x: print.maxX, y: print.maxY)))
                guard style.hasCaption else { return }
                let ink = GraphicsContext.Shading.color(tone.secondaryInk.color)
                let y = print.maxY + max(2, CGFloat(layout.referenceEdge) * 0.04 * scale)
                if style == .gallery || (style == .story && layout.variant != "wide") {
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.2, y: y, width: print.width * 0.6, height: 1)), with: ink)
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.3, y: y + 2.5, width: print.width * 0.4, height: 1)), with: ink)
                } else {
                    context.fill(Path(CGRect(x: print.minX, y: y, width: print.width * 0.42, height: 1)), with: ink)
                    context.fill(Path(CGRect(x: print.maxX - print.width * 0.24, y: y, width: print.width * 0.24, height: 1)), with: ink)
                }
            }
        } else {
            Image(systemName: "nosign")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Names

extension FrameStyle {
    var title: LocalizedStringKey {
        switch self {
        case .gallery: "ios.frame.style.gallery"
        case .label: "ios.frame.style.label"
        case .story: "ios.frame.style.story"
        case .instant: "ios.frame.style.instant"
        case .hairline: "ios.frame.style.hairline"
        }
    }
}

extension FrameTone {
    var title: LocalizedStringKey {
        switch self {
        case .paper: "ios.frame.tone.paper"
        case .snow: "ios.frame.tone.snow"
        case .mist: "ios.frame.tone.mist"
        case .graphite: "ios.frame.tone.graphite"
        case .ink: "ios.frame.tone.ink"
        }
    }
}

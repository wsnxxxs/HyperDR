import SwiftUI
import HyperDRDesign
import HyperDREngine

/// File ▸ Frame…: the presentation frame around the photograph, previewed on
/// a live EDR canvas. The frame is drawn in SDR, so on an HDR display it sits
/// at reference white while the photograph shows its real highlights -- what
/// the export will look like. The choice is kept and applied by export.
struct FrameSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.hdr.previewBackdrop)
                Divider()
                ScrollView {
                    FrameSettingsPanel(settings: $model.frame)
                        .padding(Layout.panelPadding)
                }
                .frame(width: 340)
                .background(Color.hdr.surfacePanel)
            }
            Divider()
            footer
        }
        .frame(minWidth: 960, idealWidth: 1120, minHeight: 640, idealHeight: 740)
        .background(Color.hdr.surfacePanel)
        .task(id: model.document?.name) { await model.loadCaptureFacts() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Text("frame.title")
                .font(Font.hdr.title)
                .foregroundStyle(Color.hdr.inkStrong)
            if let document = model.document {
                Text(verbatim: subtitle(document))
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Spacer()
        }
        .padding(.horizontal, Layout.panelPadding)
        .padding(.vertical, Space.s4)
    }

    @ViewBuilder private var preview: some View {
        if let layout = model.frameLayout {
            FramedPhoto(layout: layout, settings: model.frame, caption: model.frameCaption) {
                FramePreviewCanvas(model: model)
            }
            .padding(.horizontal, Space.s6)
            .padding(.top, Space.s6)
            .padding(.bottom, 56)
            .overlay(alignment: .bottomLeading) { DisplayNote(display: model.display).padding(Space.s4) }
        } else {
            Text("frame.unavailable")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.overlayInk)
        }
    }

    private var footer: some View {
        HStack {
            if let layout = model.frameLayout {
                Text("frame.output \("\(layout.width) × \(layout.height)")")
                    .font(Font.hdr.readout)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Spacer()
            Button("frame.done") { dismiss() }
                .buttonStyle(.hdrPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Layout.panelPadding)
        .padding(.vertical, Space.s3)
    }

    private func subtitle(_ document: DocumentState) -> String {
        guard let size = document.pixelSize else { return document.name }
        return "\(document.name) · \(size.width) × \(size.height)"
    }
}

/// Under the preview: what the frame does on this display.
private struct DisplayNote: View {
    let display: DisplayState

    var body: some View {
        HStack(spacing: Space.s2) {
            if display.supportsEDR { HDRBadge() }
            Text(display.supportsEDR ? "frame.preview.hdr" : "frame.preview.sdr")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.overlayInk)
        }
        .hdrOverlayChip()
    }
}

// MARK: - Settings

/// The frame's controls: on or off, the five styles, the paper tone, the
/// caption and the print shadow.
struct FrameSettingsPanel: View {
    @Binding var settings: FrameSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Toggle("frame.enabled", isOn: $settings.isEnabled)
                    .toggleStyle(HDRSwitchToggleStyle())
                Text("frame.enabled.note")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
            Divider()
            VStack(alignment: .leading, spacing: Space.s4) {
                styles
                tones
                Divider()
                captionControls
                Toggle("frame.shadow", isOn: $settings.showsShadow)
                    .toggleStyle(HDRSwitchToggleStyle())
                    .disabled(settings.style.geometry.shadow == nil)
            }
            .disabled(!settings.isEnabled)
            .opacity(settings.isEnabled ? 1 : 0.45)
        }
    }

    private var styles: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionHeading("frame.style")
            HStack(spacing: Space.s2) {
                ForEach(FrameStyle.allCases) { style in
                    Button { withHDRAnimation { settings.style = style } } label: {
                        StyleTile(style: style, tone: settings.tone, selected: settings.style == style)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.style == style ? .isSelected : [])
                }
            }
            Text(settings.style.note)
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tones: some View {
        HStack(spacing: Space.s2) {
            SectionHeading("frame.tone")
            Spacer()
            ForEach(FrameTone.allCases) { tone in
                Button { settings.tone = tone } label: {
                    Circle()
                        .fill(tone.background.color)
                        .overlay { Circle().strokeBorder(Color.hdr.lineStrong) }
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay {
                            if settings.tone == tone { Circle().strokeBorder(Color.hdr.accent, lineWidth: 2) }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text(tone.title))
                .accessibilityLabel(Text(tone.title))
                .accessibilityAddTraits(settings.tone == tone ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var captionControls: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SectionHeading("frame.text")
            if settings.style.hasCaption {
                Toggle("frame.text.exposure", isOn: $settings.showsExposure)
                    .toggleStyle(HDRSwitchToggleStyle())
                Toggle("frame.text.camera", isOn: $settings.showsCamera)
                    .toggleStyle(HDRSwitchToggleStyle())
                Toggle("frame.text.date", isOn: $settings.showsDate)
                    .toggleStyle(HDRSwitchToggleStyle())
                LabeledContent {
                    TextField(text: $settings.signature, prompt: Text("frame.signature.prompt")) {
                        Text("frame.signature")
                    }
                    .textFieldStyle(.roundedBorder)
                } label: {
                    Text("frame.signature")
                        .font(Font.hdr.caption)
                }
            } else {
                Text("frame.text.none")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
        }
    }
}

/// A style's proportions in miniature, laid out by the engine around a
/// nominal 2:3 print, on the chosen paper.
private struct StyleTile: View {
    let style: FrameStyle
    let tone: FrameTone
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                var settings = FrameSettings()
                settings.style = style
                guard let layout = try? Engine.frameLayout(frame: settings.engineFrame(hasCaption: style.hasCaption),
                                                           photoWidth: 1000, photoHeight: 1500) else { return }
                let scale = min(size.width / CGFloat(layout.width), size.height / CGFloat(layout.height))
                let canvas = CGRect(x: (size.width - CGFloat(layout.width) * scale) / 2,
                                    y: (size.height - CGFloat(layout.height) * scale) / 2,
                                    width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
                context.fill(Path(canvas), with: .color(tone.background.color))
                let print = CGRect(x: canvas.minX + CGFloat(layout.photo.x) * scale,
                                   y: canvas.minY + CGFloat(layout.photo.y) * scale,
                                   width: CGFloat(layout.photo.width) * scale,
                                   height: CGFloat(layout.photo.height) * scale)
                context.fill(Path(print), with: .color(.gray))
                guard style.hasCaption else { return }
                let ink = GraphicsContext.Shading.color(tone.secondaryInk.color)
                let y = print.maxY + max(2, CGFloat(layout.referenceEdge) * 0.04 * scale)
                switch style {
                case .gallery, .story:
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.2, y: y, width: print.width * 0.6, height: 1.5)), with: ink)
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.3, y: y + 3, width: print.width * 0.4, height: 1.5)), with: ink)
                default:
                    context.fill(Path(CGRect(x: print.minX, y: y, width: print.width * 0.42, height: 1.5)), with: ink)
                    context.fill(Path(CGRect(x: print.maxX - print.width * 0.24, y: y, width: print.width * 0.24, height: 1.5)), with: ink)
                }
            }
            .frame(width: 52, height: 68)
            .background(Color.hdr.previewBackdrop, in: .rect(cornerRadius: Radius.standard))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.standard)
                    .strokeBorder(selected ? Color.hdr.accent : Color.hdr.line, lineWidth: selected ? 2 : 1)
            }
            Text(style.title)
                .font(selected ? Font.hdr.controlLabel : Font.hdr.caption)
                .foregroundStyle(selected ? Color.hdr.inkStrong : Color.hdr.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Names

extension FrameStyle {
    var title: LocalizedStringKey {
        switch self {
        case .gallery: "frame.style.gallery"
        case .label: "frame.style.label"
        case .story: "frame.style.story"
        case .instant: "frame.style.instant"
        case .hairline: "frame.style.hairline"
        }
    }

    var note: LocalizedStringKey {
        switch self {
        case .gallery: "frame.style.gallery.note"
        case .label: "frame.style.label.note"
        case .story: "frame.style.story.note"
        case .instant: "frame.style.instant.note"
        case .hairline: "frame.style.hairline.note"
        }
    }
}

extension FrameTone {
    var title: LocalizedStringKey {
        switch self {
        case .paper: "frame.tone.paper"
        case .snow: "frame.tone.snow"
        case .mist: "frame.tone.mist"
        case .graphite: "frame.tone.graphite"
        case .ink: "frame.tone.ink"
        }
    }
}

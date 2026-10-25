import SwiftUI
import HyperDRDesign
import UniformTypeIdentifiers

/// File ▸ Frame…: the presentation frame around the photograph, previewed on
/// a live EDR canvas. The frame is drawn in SDR, so on an HDR display it sits
/// at reference white while the photograph shows its real highlights -- what
/// the export will look like. The choice is kept and applied by export.
struct FrameSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var activeState
    /// "Hold for SDR": view state, not the model's -- it only changes what
    /// the preview shows.
    @State private var compare = FrameSDRCompare()
    @FocusState private var previewFocused: Bool
    /// The preview took focus from a click, not the keyboard: no ring.
    @State private var focusedByPointer = false
    /// The sheet is still opening: the preview, its first focusable view,
    /// gets the focus the sheet hands out, which nobody asked for with a key.
    @State private var isOpening = true

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
                    FrameSettingsPanel(settings: $model.frame, photoSize: model.document?.pixelSize,
                                       lock: model.editingLockReason)
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
        .onChange(of: CompareInputs(supportsEDR: model.display.supportsEDR, hasHDR: model.frameCompareHasHDR), initial: true) { _, inputs in
            compare.configure(supportsEDR: inputs.supportsEDR, hasHDR: inputs.hasHDR)
        }
        // A key-up never arrives once the window is not key.
        .onChange(of: activeState) { if activeState == .inactive { compare.releaseAll() } }
        .onChange(of: model.photoSerial) { compare.releaseAll() }
        .onDisappear { compare.releaseAll() }
    }

    private struct CompareInputs: Equatable {
        var supportsEDR: Bool
        var hasHDR: Bool
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

    /// The settings the preview draws: with the switch off, the bare photograph.
    private var previewSettings: FrameSettings { model.frame }

    /// The caption in the layout the engine picked for this photograph.
    private func caption(for layout: FramePixelLayout) -> FrameCaption {
        previewSettings.style.caption(previewSettings, facts: model.captureFacts, variant: layout.variant,
                                  bandHeight: layout.referenceEdge > 0
                                      ? Double(layout.caption.height) / Double(layout.referenceEdge) : nil)
    }

    /// The text of a wide card stays at least this large, in points: a
    /// panorama fitted to the window would set it in specks.
    static let minimumBodyPoints: CGFloat = 10

    /// Points per engine pixel for the preview: the fit, or for a wide card
    /// with text, a scale that keeps the smallest body text at the minimum
    /// size (the preview then scrolls). No text, no minimum.
    static func previewScale(fit: CGFloat, layout: FramePixelLayout, settings: FrameSettings,
                             caption: FrameCaption) -> CGFloat {
        guard settings.isEnabled, !caption.isEmpty,
              let body = settings.style.bodySize(variant: layout.variant) else { return fit }
        return max(fit, minimumBodyPoints / (CGFloat(body) * CGFloat(layout.referenceEdge)))
    }

    /// What the canvas reports of the pointer: a press on the photograph is
    /// a possible hold, and the click gives the preview the keyboard.
    private var pointer: CanvasPointerHandlers {
        CanvasPointerHandlers(
            down: { point in takePreviewFocus(); compare.pointerMoved(start: point, to: point) },
            drag: { point in compare.pointerMoved(start: point, to: point) },
            up: { compare.pointerEnded() })
    }

    private func takePreviewFocus() {
        focusedByPointer = true
        previewFocused = true
    }

    /// The same press over the mat and the caption, which are SwiftUI.
    private func matPressed(_ press: FramePress?) {
        if press != nil, !previewFocused { takePreviewFocus() }
        compare.matPress(press)
    }

    @ViewBuilder private var preview: some View {
        if let layout = model.frameLayout {
            GeometryReader { proxy in
                let available = CGSize(width: max(proxy.size.width - 2 * Space.s6, 1),
                                       height: max(proxy.size.height - Space.s6 - 56, 1))
                let fit = min(available.width / CGFloat(layout.width), available.height / CGFloat(layout.height))
                let text = caption(for: layout)
                let scale = Self.previewScale(fit: fit, layout: layout, settings: previewSettings, caption: text)
                let framed = FramedPhoto(layout: layout, settings: previewSettings, caption: text) {
                    FramePreviewCanvas(model: model, showsSDR: compare.showsSDR, pointer: pointer)
                }
                // The card's top edge: it is centred in the space offered, or,
                // for a card that scrolls, at the top of it.
                let cardTop = scale > fit ? Space.s6 : Space.s6 + max(0, (available.height - CGFloat(layout.height) * fit) / 2)
                ZStack(alignment: .top) {
                    if scale > fit {
                        ScrollView(.horizontal) {
                            framed
                                .frame(width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
                                .padding(.horizontal, Space.s6)
                                .contentShape(.rect)
                                .reportsPress(simultaneous: true, matPressed)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxHeight: .infinity)
                        .padding(.top, Space.s6)
                        .padding(.bottom, 56)
                    } else {
                        framed
                            .padding(.horizontal, Space.s6)
                            .padding(.top, Space.s6)
                            .padding(.bottom, 56)
                            .contentShape(.rect)
                            .reportsPress(simultaneous: true, matPressed)
                    }
                    if compare.showsSDR {
                        FrameSDRLabel(compare: compare).padding(.top, cardTop + 12)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .overlay(alignment: .bottom) { FrameCompareBar(display: model.display, compare: compare) }
            .overlay { if previewFocused && !focusedByPointer { FocusRing() } }
            .focusable()
            .focusEffectDisabled()
            .focused($previewFocused)
            .onChange(of: previewFocused) { _, now in
                if now && isOpening { focusedByPointer = true }
                if !now { focusedByPointer = false; compare.keyboardLeft() }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(500))
                isOpening = false
            }
            .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { press in
                guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
                switch press.phase {
                case .down: compare.spaceDown()
                case .up: compare.spaceUp()
                default: break
                }
                return .handled
            }
            .onKeyPress(.escape) { compare.escape() ? .handled : .ignored }
            // The preview going away (no layout any more) takes its presses,
            // keys and focus with it; nothing may stay held.
            .onDisappear { compare.releaseAll() }
        } else if model.document?.pixelSize != nil {
            Text("frame.style.unavailable")
                .font(Font.hdr.control)
                .foregroundStyle(Color.hdr.overlayInk)
                .multilineTextAlignment(.center)
                .padding(Space.s6)
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
struct DisplayNote: View {
    let display: DisplayState
    /// The photograph shows its SDR version: the HDR badge goes and the note
    /// says what the picture is now.
    var showsSDR = false

    var body: some View {
        HStack(spacing: Space.s2) {
            if display.supportsEDR && !showsSDR { HDRBadge() }
            Text(showsSDR ? "frame.compare.sdr.note" : display.supportsEDR ? "frame.preview.hdr" : "frame.preview.sdr")
                .font(Font.hdr.caption)
                .foregroundStyle(Color.hdr.overlayInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .hdrOverlayChip()
    }
}

// MARK: - Settings

/// The frame's controls: on or off, the five styles, the paper tone, the
/// caption and the print shadow.
struct FrameSettingsPanel: View {
    @Binding var settings: FrameSettings
    /// The photograph's size, which shapes the style miniatures; nil before
    /// it is known (a nominal 2:3 print).
    var photoSize: PixelSize? = nil
    /// Why the photograph can't change now. The settings follow the inspector:
    /// system-disabled and still readable, and while an export runs they say
    /// why (M3 §5.2).
    var lock: EditingLockReason? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if lock == .exporting {
                Label("exportLock.help", systemImage: "lock.fill")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
                .disabled(lock != nil)
                // The note's tooltip lives on a layer of its own while an export
                // runs, so no control's tooltip (or lack of one) hides it.
                .overlay { if lock == .exporting { Color.clear.contentShape(.rect).help(Text("exportLock.help")) } }
        }
    }

    private var controls: some View {
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
                shadowToggle
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
                        StyleTile(style: style, tone: settings.tone, photoSize: photoSize,
                                  selected: settings.style == style)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.style == style ? .isSelected : [])
                }
            }
            if EditorModel.frameLayout(for: settings.style, photoSize: photoSize) == nil {
                // The engine refused this style for the photograph (a hand-written
                // spec or an extreme proportion): no frame is drawn.
                Label("frame.style.unavailable", systemImage: "exclamationmark.triangle")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    /// A style without a shadow shows the switch off, not the choice it
    /// keeps for the styles that have one.
    @ViewBuilder private var shadowToggle: some View {
        let hasShadow = settings.style.geometry.shadow != nil
        Toggle("frame.shadow", isOn: Binding(get: { hasShadow && settings.showsShadow },
                                             set: { settings.showsShadow = $0 }))
            .toggleStyle(HDRSwitchToggleStyle())
            .disabled(!hasShadow)
            .help(hasShadow ? Text(verbatim: "") : Text("frame.shadow.none"))
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
                FrameTypefaceControls(settings: $settings)
            } else {
                Text("frame.text.none")
                    .font(Font.hdr.caption)
                    .foregroundStyle(Color.hdr.inkMuted)
            }
        }
    }
}

/// The caption's typefaces: one for its lines, one for the signature, each a
/// system design, a family the system ships, or a font the person imported.
private struct FrameTypefaceControls: View {
    @Binding var settings: FrameSettings
    @State private var importing = false
    @State private var importFailed = false
    private var library: FrameFontLibrary { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            SectionHeading("frame.font")
            picker("frame.font.text", selection: $settings.textFace)
            picker("frame.font.signature", selection: $settings.signatureFace)
            HStack(spacing: Space.s2) {
                Button("frame.font.import") { importing = true }
                    .buttonStyle(.hdrSecondary)
                Spacer()
                if !library.families.isEmpty {
                    Menu("frame.font.manage") {
                        ForEach(library.entries) { entry in
                            Button(role: .destructive) { remove(entry) } label: {
                                Text("frame.font.remove \(entry.families.joined(separator: ", "))")
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            if importFailed {
                InspectorNotice(Text("frame.font.importFailed"), style: .warning)
            }
            if !settings.textFace.isAvailable || !settings.signatureFace.isAvailable {
                InspectorNotice(Text("frame.font.missing"), style: .warning)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.font], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let family = try library.importFont(from: url)
                importFailed = false
                settings.textFace = .family(family)
            } catch {
                importFailed = true
            }
        }
    }

    private func picker(_ title: LocalizedStringKey, selection: Binding<FrameTypeface>) -> some View {
        LabeledContent {
            Picker(selection: selection) {
                ForEach(FrameTypeface.designs) { face in
                    face.title.tag(face)
                }
                Divider()
                ForEach(library.offeredFamilies(), id: \.self) { family in
                    Text(verbatim: family).tag(FrameTypeface.family(family))
                }
                // A family chosen on another Mac, or removed since, stays listed.
                if let family = selection.wrappedValue.familyName, !library.offeredFamilies().contains(family) {
                    Text("frame.font.unavailable \(family)").tag(selection.wrappedValue)
                }
            } label: {
                Text(title)
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text(title).font(Font.hdr.caption)
        }
    }

    private func remove(_ entry: FrameFontLibrary.Entry) {
        for keyPath in [\FrameSettings.textFace, \.signatureFace]
        where entry.families.contains(settings[keyPath: keyPath].familyName ?? "") {
            settings[keyPath: keyPath] = keyPath == \.textFace ? .system : .serif
        }
        library.remove(entry)
    }
}

extension FrameTypeface {
    var title: Text {
        switch self {
        case .system: Text("frame.font.system")
        case .serif: Text("frame.font.serif")
        case .rounded: Text("frame.font.rounded")
        case .monospaced: Text("frame.font.monospaced")
        case .family(let name): Text(verbatim: name)
        }
    }
}

/// A style's proportions in miniature, laid out by the engine around this
/// photograph (a nominal 2:3 print before its size is known), on the chosen
/// paper.
private struct StyleTile: View {
    let style: FrameStyle
    let tone: FrameTone
    let photoSize: PixelSize?
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let layout = EditorModel.frameLayout(for: style, photoSize: photoSize)
        VStack(spacing: 6) {
            Canvas { context, size in
                guard let layout else { return }
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
                if style == .gallery || (style == .story && layout.variant != "wide") {
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.2, y: y, width: print.width * 0.6, height: 1.5)), with: ink)
                    context.fill(Path(CGRect(x: print.minX + print.width * 0.3, y: y + 3, width: print.width * 0.4, height: 1.5)), with: ink)
                } else {
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
        .opacity(isEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity)
    }
}

extension EditorModel {
    /// A style's layout around a photograph of `size` (a nominal 2:3 print
    /// before the size is known); nil if the engine rejects it.
    static func frameLayout(for style: FrameStyle, photoSize: PixelSize?) -> FramePixelLayout? {
        guard let photoSize else { return frameLayout(for: style) }
        return frameLayout(for: style, photoWidth: photoSize.width, photoHeight: photoSize.height)
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

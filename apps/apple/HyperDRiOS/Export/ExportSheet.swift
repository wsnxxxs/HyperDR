import HyperDRDesign
import HyperDRKit
import HyperDRRender
import SwiftUI
import UniformTypeIdentifiers

/// The iOS export sheet (P7-3b-U; p7-adjustments §4.1, §4.4). One strip of
/// tiles answers "what for": the destinations first, then the four file
/// formats. Under it, only the settings that apply to that choice, each one
/// tap away in a menu, and at the foot what will be written above the main
/// button. Changing a setting on a destination starts a custom format from
/// the destination's settings. Once started the sheet is the progress, then
/// the result with Save to Files and Share, or the failure. While it runs the
/// sheet cannot be swiped away, which keeps the editor locked.
///
/// On the iPad (ipad-studio §5) the sheet is a large page: what will be
/// written, live and in HDR, takes the left, and the same column of choices,
/// progress and result the iPhone shows stands on the right.
struct ExportSheet: View {
    @Bindable var model: IOSExportModel
    let editor: RecipeEditor
    /// The frame exports carry; turned off here for one export or for good.
    @Binding var frame: FrameSettings
    /// The iPad's preview beside the column; nil on the iPhone.
    var preview: AnyView? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var detent = PresentationDetent.large
    @State private var typingLongEdge = false
    @State private var longEdgeDraft = ""

    /// The quality menu's steps; the current value joins them when it is none.
    private static let qualities = [100, 95, 90, 85, 80, 70, 60]
    /// The strip's destinations: Photos last.
    private static let destinations: [ExportDestination] = [.web, .social, .photos]
    /// The column of choices beside the iPad's preview.
    private static let columnWidth: CGFloat = 420

    var body: some View {
        NavigationStack {
            Group {
                if let preview {
                    HStack(spacing: 0) {
                        preview
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        content
                            .frame(width: Self.columnWidth)
                    }
                } else {
                    content
                }
            }
            .navigationTitle(Text("ios.export.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.isRunning {
                        Button("ios.export.cancel") { model.cancel() }
                    } else {
                        Button(role: .close) { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isRunning)
        .modifier(ExportSheetPresentation(isPage: preview != nil, detent: $detent))
        .onChange(of: model.isChoosing) { _, choosing in
            withAnimation { detent = choosing ? .large : .medium }
        }
        .fileExporter(isPresented: $model.presentingFileExporter, document: exportedFile,
                      contentType: exportedFile?.contentType ?? .image,
                      defaultFilename: suggestedName) { model.savedToFiles($0) }
    }

    /// The staged copy is already named after the photo: "DSC04127.jpg".
    private var suggestedName: String? { exportedFile?.url.lastPathComponent }

    private var exportedFile: ExportedFile? {
        if case .finished(let finished) = model.phase { return ExportedFile(url: finished.file) }
        return nil
    }

    /// The phases cross-fade: the choices give way to the ring, the ring to
    /// the result or the failure.
    private var content: some View {
        ZStack {
            switch model.phase {
            case .choosing: choosing(model.plan(editor)).transition(Self.phaseTransition)
            case .running(let progress): running(progress).transition(Self.phaseTransition)
            case .finished(let finished): result(finished).transition(Self.phaseTransition)
            case .failed(let failure): failed(failure).transition(Self.phaseTransition)
            }
        }
        .animation(.smooth(duration: 0.35), value: model.phaseKind)
    }

    private static let phaseTransition = AnyTransition.opacity.combined(with: .scale(scale: 0.97))

    // MARK: - Choosing

    private func choosing(_ plan: ExportPlan?) -> some View {
        let format = model.shownFormat(plan)
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.s5) {
                strip(format)
                VStack(alignment: .leading, spacing: Space.s2) {
                    hint(format)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Space.s5)
                    settings(format, plan)
                }
                messages(plan)
            }
            .padding(.top, Space.s2)
            .padding(.bottom, Space.s4)
            .animation(.smooth(duration: 0.25), value: format)
        }
        .scrollBounceBehavior(.basedOnSize)
        .tint(Color.hdr.accent)
        .safeAreaInset(edge: .bottom) { footer(plan) }
        .sensoryFeedback(.selection, trigger: model.choice)
        .alert(Text("ios.export.longEdge.custom"), isPresented: $typingLongEdge) {
            TextField(text: $longEdgeDraft, prompt: Text("ios.export.originalSize")) { Text("ios.export.longEdge.custom") }
                .keyboardType(.numberPad)
            Button("ios.adjust.cancel", role: .cancel) {}
            Button("ios.adjust.apply") {
                let photo = model.photoLongEdge(editor)
                model.edit(from: plan) { $0.longEdge = ExportLongEdge.normalized(Int(longEdgeDraft), photo: photo) }
            }
        }
    }

    // MARK: Tiles

    /// "For" (the destinations) over "Format" (the containers): two rows of
    /// tiles that share the width, so every choice is in sight at once.
    private func strip(_ format: CustomExportFormat) -> some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            tileRow(Text("ios.export.group.use")) {
                ForEach(Self.destinations, id: \.self) { destination in
                    // The plan says which destination cannot be chosen yet (Photos
                    // before its saving is verified, p7-3c-export §1.3 F).
                    let unavailable = model.unavailableReason(destination, editor)?.destinationShortPhrase
                    FormatTile(selected: model.page == .destination && model.destination == destination,
                               detail: Text(Self.name(destination))) {
                        Image(systemName: Self.icon(destination)).font(.system(size: 19))
                    } action: {
                        model.destination = destination
                        model.page = .destination
                    }
                    .disabled(unavailable != nil)
                    .accessibilityHint(unavailable.map { Text(verbatim: $0.text(locale: locale)) } ?? Text(Self.hint(destination)))
                }
            }
            tileRow(Text("ios.export.format")) {
                ForEach(ExportFamily.allCases, id: \.self) { family in
                    // A tile none of whose encodings this photo can take stays visible, disabled (K6).
                    let open = family.encodings.contains { model.unavailableReason($0, editor) == nil }
                    FormatTile(selected: model.page == .custom && ExportFamily(format.encoding) == family,
                               detail: Text(family.caption)) {
                        Text(verbatim: family.name).font(.system(size: 16, weight: .semibold, design: .rounded))
                    } action: {
                        model.select(family, editor)
                    }
                    .disabled(!open)
                }
            }
        }
        .padding(.horizontal, Space.s4)
    }

    private func tileRow(_ title: Text, @ViewBuilder tiles: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            title
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, Space.s1)
            HStack(spacing: Space.s2) { tiles() }
        }
    }

    /// One line on what the choice is for.
    private func hint(_ format: CustomExportFormat) -> Text {
        model.page == .destination ? Text(Self.hint(model.destination)) : Text(LocalizedStringKey(format.encoding.hintKey))
    }

    private static func name(_ destination: ExportDestination) -> LocalizedStringKey {
        switch destination {
        case .photos: "ios.export.dest.photos"
        case .web: "ios.export.dest.web"
        case .social: "ios.export.dest.social"
        }
    }

    private static func hint(_ destination: ExportDestination) -> LocalizedStringKey {
        switch destination {
        case .photos: "ios.export.dest.photos.hint"
        case .web: "ios.export.dest.web.hint"
        case .social: "ios.export.dest.social.hint"
        }
    }

    private static func icon(_ destination: ExportDestination) -> String {
        switch destination {
        case .photos: "photo.on.rectangle"
        case .web: "globe"
        case .social: "bubble.left.and.bubble.right"
        }
    }

    // MARK: Settings

    /// Only what applies: the encoding when the format has more than one (for
    /// TIFF and DNG, HDR output and the depth), the colour space when it is
    /// free (F2), the size, the quality (not TIFF or DNG), and the frame.
    private func settings(_ format: CustomExportFormat, _ plan: ExportPlan?) -> some View {
        let family = ExportFamily(format.encoding)
        return VStack(spacing: 0) {
            if family.isLossless {
                losslessRows(format, family, plan)
            } else if family.encodings.count > 1 {
                encodingRow(format, family, plan)
                Divider().padding(.leading, Space.s4)
            }
            if !format.encoding.gamutChoices.isEmpty, plan?.gamutIsFixedByFormat == false {
                menuRow(Text("ios.export.gamut"), value: Text(LocalizedStringKey(format.gamut.labelKey))) {
                    Picker(selection: Binding(get: { format.gamut }, set: { gamut in model.edit(from: plan) { $0.gamut = gamut } })) {
                        ForEach(format.encoding.gamutChoices, id: \.self) { Text(LocalizedStringKey($0.labelKey)).tag($0) }
                    } label: {
                        Text("ios.export.gamut")
                    }
                }
                Divider().padding(.leading, Space.s4)
            }
            sizeRow(format, plan)
            if !format.encoding.isLossless {
                Divider().padding(.leading, Space.s4)
                menuRow(Text("ios.export.qualityLabel"), value: Text(verbatim: String(format.quality))) {
                    Picker(selection: Binding(get: { format.quality }, set: { quality in model.edit(from: plan) { $0.quality = quality } })) {
                        ForEach(Array(Set(Self.qualities + [format.quality])).sorted(by: >), id: \.self) {
                            Text(verbatim: String($0)).tag($0)
                        }
                    } label: {
                        Text("ios.export.qualityLabel")
                    }
                }
            }
            Divider().padding(.leading, Space.s4)
            frameRow
        }
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, Space.s4)
    }

    /// Photoshop's "HDR Output" and colour depth: HDR writes the HDR version
    /// itself, linear; off writes the SDR version. Only an HDR TIFF has a depth
    /// to choose; the rest are 16 bits per channel.
    @ViewBuilder
    private func losslessRows(_ format: CustomExportFormat, _ family: ExportFamily, _ plan: ExportPlan?) -> some View {
        let hdr = format.encoding.isLinearHDR
        let hdrEncoding = format.encoding.hdrCounterpart(tiffDepth: model.tiffDepth)
        let reason = hdr ? nil : model.unavailableReason(hdrEncoding, editor)
        Toggle(isOn: Binding(get: { hdr }, set: { model.setHDROutput($0, from: plan) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ios.export.hdrOutput")
                if let reason { Text(verbatim: reason.phrase.text(locale: locale)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .tint(Color.hdr.accentFill)
        .disabled(reason != nil)
        .padding(.horizontal, Space.s4)
        .frame(minHeight: 52)
        Divider().padding(.leading, Space.s4)
        let depth = format.encoding.losslessBitDepth ?? 16
        if family == .tiff && hdr {
            menuRow(Text("ios.export.depth"), value: Text(Self.depthName(depth))) {
                Picker(selection: Binding(get: { depth }, set: { depth in
                    model.edit(from: plan) { $0.encoding = $0.encoding.hdrCounterpart(tiffDepth: depth) }
                })) {
                    ForEach([16, 32], id: \.self) { Text(Self.depthName($0)).tag($0) }
                } label: {
                    Text("ios.export.depth")
                }
            }
        } else {
            HStack(spacing: Space.s2) {
                Text("ios.export.depth")
                Spacer(minLength: Space.s3)
                Text(Self.depthName(depth)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.s4)
            .frame(minHeight: 52)
            .accessibilityElement(children: .combine)
        }
        Divider().padding(.leading, Space.s4)
    }

    private static func depthName(_ depth: Int) -> LocalizedStringKey {
        depth == 32 ? "ios.export.depth.32" : "ios.export.depth.16"
    }

    private func encodingRow(_ format: CustomExportFormat, _ family: ExportFamily, _ plan: ExportPlan?) -> some View {
        menuRow(Text("ios.export.encoding"), value: format.encoding.variantName) {
            // Toggles, not a picker: a menu shows a toggle's second line, which
            // says what each encoding is for.
            ForEach(family.encodings, id: \.self) { encoding in
                // The plan's answer for this encoding here (K6).
                let reason = model.unavailableReason(encoding, editor)
                Toggle(isOn: Binding(get: { format.encoding == encoding },
                                     set: { if $0 { model.edit(from: plan) { $0.encoding = encoding } } })) {
                    encoding.variantName
                    if let reason { Text(verbatim: reason.phrase.text(locale: locale)) } else { Text(LocalizedStringKey(encoding.hintKey)) }
                }
                .disabled(reason != nil && encoding != format.encoding)
            }
        }
    }

    /// Original size or a long edge: the presets smaller than the photo, or
    /// a typed number (p7-3c-export §1.3 B).
    private func sizeRow(_ format: CustomExportFormat, _ plan: ExportPlan?) -> some View {
        let photo = model.photoLongEdge(editor)
        // A limit at or above the photo's own long edge keeps the original size.
        let edge = ExportLongEdge.normalized(format.longEdge, photo: photo)
        let value = edge.map { Text("ios.export.longEdge.pixels \(String($0))") } ?? Text("ios.export.originalSize")
        return menuRow(Text("ios.export.longEdge"), value: value) {
            Picker(selection: Binding(get: { edge },
                                      set: { edge in model.edit(from: plan) { $0.longEdge = ExportLongEdge.normalized(edge, photo: photo) } })) {
                ForEach(ExportLongEdge.choices(photo: photo, current: edge), id: \.self) { edge in
                    if let edge {
                        Text("ios.export.longEdge.pixels \(String(edge))").tag(Int?.some(edge))
                    } else {
                        Text("ios.export.originalSize").tag(Int?.none)
                    }
                }
            } label: {
                Text("ios.export.longEdge")
            }
            Button("ios.export.longEdge.other", systemImage: "number") {
                longEdgeDraft = edge.map(String.init) ?? ""
                typingLongEdge = true
            }
        }
    }

    /// The frame goes with the export while it is on; the switch here is the
    /// editor's own, so turning it off here turns it off there too.
    private var frameRow: some View {
        Toggle(isOn: $frame.isEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ios.frame.title")
                if frame.isEnabled {
                    Text(frame.style.title).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .tint(Color.hdr.accentFill)
        .padding(.horizontal, Space.s4)
        .frame(minHeight: 52)
    }

    /// A row whose value opens a menu of choices.
    private func menuRow(_ title: Text, value: Text, @ViewBuilder menu: () -> some View) -> some View {
        Menu {
            menu()
        } label: {
            HStack(spacing: Space.s2) {
                title.foregroundStyle(.primary)
                Spacer(minLength: Space.s3)
                value.foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Space.s4)
            .frame(minHeight: 52)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Notes and the foot

    /// The plan's notes and anything that blocks the export, under the settings.
    @ViewBuilder private func messages(_ plan: ExportPlan?) -> some View {
        let notices = plan?.notices ?? []
        let blockers = plan?.blockers ?? []
        let lutMissing = model.luts.missingLook(editor)
        let misfits = model.frameMisfits(editor)
        let warnsCompatibility = editor.sourceCompatibility?.isWarning == true
        if warnsCompatibility || !notices.isEmpty || !blockers.isEmpty || lutMissing != nil || misfits || model.sessionFailure != nil {
            VStack(alignment: .leading, spacing: Space.s2) {
                if warnsCompatibility {
                    note(Text("ios.compat.preview.export"), symbol: "exclamationmark.triangle", warning: true)
                }
                ForEach(notices, id: \.self) { notice in
                    note(Text(verbatim: notice.phrase.text(locale: locale)), symbol: "info.circle", warning: false)
                }
                if let look = lutMissing {
                    note(Text("ios.export.lutMissing \(look.name)"), symbol: "exclamationmark.triangle", warning: true)
                }
                if misfits {
                    note(Text("ios.frame.misfit"), symbol: "exclamationmark.triangle", warning: true)
                }
                ForEach(blockers, id: \.self) { blocker in
                    note(Text(verbatim: blocker.phrase.text(locale: locale)), symbol: "exclamationmark.triangle", warning: true)
                    if let edge = blocker.suggestedLongEdge {
                        Button { model.useLongEdge(edge, from: plan) } label: {
                            Text(verbatim: ExportReasonPhrase.useLongEdge(edge).text(locale: locale))
                        }
                        .buttonStyle(.glass)
                        .padding(.leading, 26)
                    }
                }
                if model.sessionFailure != nil {
                    note(Text("ios.export.unavailable"), symbol: "exclamationmark.triangle", warning: true)
                }
            }
            .padding(.horizontal, Space.s5)
        }
    }

    private func note(_ text: Text, symbol: String, warning: Bool) -> some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.footnote)
            .foregroundStyle(warning ? Color.hdr.warn : Color.secondary)
    }

    /// What will be written, then the main button.
    private func footer(_ plan: ExportPlan?) -> some View {
        VStack(spacing: Space.s3) {
            if let plan {
                HStack(spacing: Space.s1) {
                    if plan.peakStops != nil {
                        Image(systemName: "sun.max.fill").foregroundStyle(Color.hdr.amber)
                    }
                    Text(verbatim: summary(plan)).monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("ios.export.willWrite") + Text(verbatim: " " + summary(plan)))
            }
            Button { model.start(editor) } label: {
                primaryLabel(plan)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s1)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.hdr.accentFill)
            .controlSize(.large)
            .disabled(!model.canStart(plan, editor))
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s2)
        .padding(.bottom, Space.s2)
    }

    /// The encoding, then size · colour space · peak.
    private func summary(_ plan: ExportPlan) -> String {
        let written = model.outputSize(plan, editor)
        let size = "\(written.width) × \(written.height)"
        let peak = plan.peakStops.map { String(localized: "ios.export.peak \(ExportPlanText.stops($0))") }
            ?? String(localized: "ios.export.sdrOnly")
        return [String(localized: String.LocalizationValue(plan.encoding.labelKey)), size,
                String(localized: String.LocalizationValue(plan.gamut.labelKey)), peak].joined(separator: " · ")
    }

    /// One word for every destination: the tiles above already say where it goes.
    private func primaryLabel(_ plan: ExportPlan?) -> Text {
        Text("ios.export.start")
    }

    // MARK: - Running, result, failure

    /// One ring for the whole export (every pass of the writer, then checking
    /// and saving the file), filled once, over Kit's words for the stage.
    private func running(_ progress: RecipeExportProgress?) -> some View {
        let fraction = model.fraction
        let progress = progress ?? RecipeExportProgress(stage: .preparing)
        return VStack(spacing: Space.s5) {
            Spacer(minLength: 0)
            ExportProgressRing(fraction: fraction, finishing: progress.isFinishing)
                .frame(width: 96, height: 96)
            VStack(spacing: Space.s2) {
                // A new stage's words replace the last ones in place.
                Text(verbatim: progress.stageMessage.localized(locale: locale))
                    .font(.headline)
                    .id(progress.stageMessage.key)
                    .transition(.blurReplace)
                Text("ios.export.stayInApp")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .animation(.smooth(duration: 0.3), value: progress.stageMessage.key)
            Spacer(minLength: 0)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func result(_ finished: IOSExportModel.Finished) -> some View {
        VStack(spacing: Space.s4) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(spacing: Space.s1) {
                Text("ios.export.finished").font(.title3.weight(.semibold))
                Text(verbatim: "\(finished.file.lastPathComponent) · \(ExportPlanText.bytes(Int(finished.result.record.byteCount)))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let ceiling = IOSExportModel.appliedCeiling(finished.result) {
                Label { Text("ios.export.ceiling \(ExportPlanText.stops(ceiling))") } icon: { Image(systemName: "info.circle") }
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if finished.savedToFiles { Label("ios.export.saved", systemImage: "folder.fill").font(.subheadline) }
            if finished.deliveryFailed { Text("ios.export.deliveryFailed").font(.footnote).foregroundStyle(Color.hdr.warn) }
            if case .failed(let key) = finished.photos {
                Text(LocalizedStringKey(key)).font(.footnote).foregroundStyle(Color.hdr.warn).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
            // One height for every button, the choice page's main button's:
            // Photos across the width, Files and Share halves under it.
            GlassEffectContainer {
                VStack(spacing: Space.s2) {
                    photosButton(finished.photos)
                    HStack(spacing: Space.s2) {
                        Button { model.presentingFileExporter = true } label: {
                            ResultButtonLabel(title: "ios.export.saveToFiles", symbol: "folder")
                        }
                        .buttonStyle(.glass)
                        .foregroundStyle(.primary)
                        ShareLink(item: finished.file) {
                            ResultButtonLabel(title: "ios.export.share", symbol: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                        .foregroundStyle(.primary)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.top, Space.s5)
        .padding(.bottom, Space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func photosButton(_ state: IOSExportModel.PhotosSave) -> some View {
        Button { model.saveToPhotos() } label: {
            switch state {
            case .idle, .failed: ResultButtonLabel(title: "ios.export.saveToPhotos", symbol: "photo.badge.plus")
            case .saving: ResultButtonLabel(title: "ios.export.savingToPhotos", symbol: nil)
            case .saved: ResultButtonLabel(title: "ios.export.savedToPhotos", symbol: "checkmark")
            }
        }
        .buttonStyle(.glassProminent)
        .tint(Color.hdr.accentFill)
        .disabled(state == .saving || state == .saved)
    }

    private func failed(_ failure: IOSExportModel.Failure) -> some View {
        VStack(spacing: Space.s3) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44)).foregroundStyle(Color.hdr.warn)
            Text("ios.export.failed").font(.title3.weight(.semibold))
            Text(LocalizedStringKey(failure.key)).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let memory = failure.memory {
                Text(verbatim: memory).font(.footnote).multilineTextAlignment(.center)
            }
            if let detail = failure.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            VStack(spacing: Space.s2) {
                // Out of memory: the largest long edge that fits, back on the choice.
                if let edge = failure.suggestedLongEdge {
                    Button {
                        model.useLongEdge(edge, from: model.plan(editor))
                        model.reset()
                    } label: {
                        Text(verbatim: ExportReasonPhrase.useLongEdge(edge).text(locale: locale)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                if failure.restartable {
                    Button { model.start(editor) } label: { Text("ios.export.restart").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.hdr.accentFill)
                    Button("ios.export.done") { model.reset() }
                } else {
                    Button { model.reset() } label: { Text("ios.export.retry").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                        .tint(Color.hdr.accentFill)
                }
            }
            .controlSize(.large)
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The iPhone's sheet rises in two heights; the iPad's is a page, which has
/// room for the preview beside the choices.
private struct ExportSheetPresentation: ViewModifier {
    let isPage: Bool
    @Binding var detent: PresentationDetent

    func body(content: Content) -> some View {
        if isPage {
            content
                .presentationSizing(LightboxSizing())
                .presentationBackground(.regularMaterial)
        } else {
            content
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationBackground(.regularMaterial)
        }
    }
}

/// The iPad's export page asks for a lightbox's size, landscape, which the
/// system fits into the window.
struct LightboxSizing: PresentationSizing {
    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        ProposedViewSize(width: 1180, height: 860)
    }
}

/// A result button's label: a symbol (or a spinner) and one line of text,
/// as tall as the choice page's main button.
private struct ResultButtonLabel: View {
    let title: LocalizedStringKey
    let symbol: String?

    var body: some View {
        HStack(spacing: Space.s2) {
            if let symbol { Image(systemName: symbol) } else { ProgressView() }
            Text(title).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s1)
    }
}

/// A tile of the export strip: a mark (a symbol or the format's name) and
/// a word under it. The chosen tile is lit and outlined.
private struct FormatTile<Mark: View>: View {
    let selected: Bool
    let detail: Text
    @ViewBuilder let mark: Mark
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                mark
                    .frame(height: 24)
                    .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.8))
                detail
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, Space.s1)
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .background(shape.fill(Color.primary.opacity(selected ? 0.16 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(selected ? 0.6 : 0.08), lineWidth: selected ? 1.5 : 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A finished version for `fileExporter`: the staged copy, as it is.
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.image] }
    let url: URL

    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws { throw CocoaError(.featureUnsupported) }

    var contentType: UTType { UTType(filenameExtension: url.pathExtension) ?? .image }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

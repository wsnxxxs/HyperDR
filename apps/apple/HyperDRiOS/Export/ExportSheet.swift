import HyperDRDesign
import HyperDRKit
import SwiftUI
import UniformTypeIdentifiers

/// The iOS export sheet (P7-3b-U; p7-adjustments §4.1, §4.4): what will be
/// written at the top, then Destination | Custom Format with the destination
/// rows or the encodings and their settings, the frame, and the main button at
/// the foot. Once started the sheet is the progress, then the result with
/// Save to Files and Share, or the failure. While it runs the sheet cannot be
/// swiped away, which keeps the editor locked.
struct ExportSheet: View {
    @Bindable var model: IOSExportModel
    let editor: RecipeEditor
    /// The frame exports carry; turned off here for one export or for good.
    @Binding var frame: FrameSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var detent = PresentationDetent.large

    var body: some View {
        NavigationStack {
            content
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
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground(.regularMaterial)
        .onChange(of: model.isChoosing) { _, choosing in
            withAnimation { detent = choosing ? .large : .medium }
        }
        .fileExporter(isPresented: $model.presentingFileExporter, document: exportedFile,
                      contentType: exportedFile?.contentType ?? .image,
                      defaultFilename: suggestedName) { model.savedToFiles($0) }
    }

    /// The photo's own name with the export's extension: "DSC04127.jpg".
    private var suggestedName: String? {
        guard let file = exportedFile?.url else { return nil }
        guard let photo = editor.source?.url.deletingPathExtension().lastPathComponent, !photo.isEmpty else {
            return file.lastPathComponent
        }
        return photo + "." + file.pathExtension
    }

    private var exportedFile: ExportedFile? {
        if case .finished(let finished) = model.phase { return ExportedFile(url: finished.file) }
        return nil
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choosing: choosing(model.plan(editor))
        case .running(let progress): running(progress)
        case .finished(let finished): result(finished)
        case .failed(let failure): failed(failure)
        }
    }

    // MARK: - Choosing

    private func choosing(_ plan: ExportPlan?) -> some View {
        Form {
            if let plan { willWrite(plan) }
            Section {
                Picker(selection: $model.page) {
                    Text("ios.export.page.destination").tag(IOSExportModel.Page.destination)
                    Text("ios.export.page.custom").tag(IOSExportModel.Page.custom)
                } label: {
                    Text("ios.export.title")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if model.page == .destination {
                destinations
                Section {
                    Button("ios.export.useCustom") { model.useCustomFormat(from: plan) }
                }
            } else {
                encodings
                if let plan { customControls(plan) }
            }
            frameSection
            if model.sessionFailure != nil {
                Text("ios.export.unavailable").foregroundStyle(.secondary)
            }
        }
        .contentMargins(.top, Space.s2, for: .scrollContent)
        .tint(Color.hdr.accent)
        .safeAreaInset(edge: .bottom) {
            Button { model.start(editor) } label: {
                primaryLabel(plan)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.s1)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!model.canStart(plan, editor))
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
        }
    }

    /// "Will write": the encoding large, then size · colour space · peak,
    /// then the plan's notes and anything that blocks the export.
    private func willWrite(_ plan: ExportPlan) -> some View {
        Section {
            HStack(alignment: .center, spacing: Space.s3) {
                Image(systemName: plan.peakStops == nil ? "photo" : "sun.max.fill")
                    .font(.title2)
                    .foregroundStyle(plan.peakStops == nil ? Color.secondary : Color.hdr.amber)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(plan.encoding.labelKey)).font(.headline)
                    Text(verbatim: summary(plan)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            ForEach(plan.notices, id: \.self) { notice in
                Label { Text(verbatim: notice.phrase.text(locale: locale)) } icon: { Image(systemName: "info.circle") }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let look = model.luts.missingLook(editor) {
                Label { Text("ios.export.lutMissing \(look.name)") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote).foregroundStyle(Color.hdr.warn)
            }
            if model.frameMisfits(editor) {
                Label { Text("ios.frame.misfit") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote).foregroundStyle(Color.hdr.warn)
            }
            ForEach(plan.blockers, id: \.self) { blocker in
                Label { Text(verbatim: blocker.phrase.text(locale: locale)) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote).foregroundStyle(Color.hdr.warn)
                if let edge = blocker.suggestedLongEdge {
                    Button { model.useLongEdge(edge, from: plan) } label: {
                        Text(verbatim: ExportReasonPhrase.useLongEdge(edge).text(locale: locale))
                    }
                }
            }
        } header: {
            Text("ios.export.willWrite")
        }
    }

    private func summary(_ plan: ExportPlan) -> String {
        let written = model.outputSize(plan, editor)
        let size = "\(written.width) × \(written.height)"
        let peak = plan.peakStops.map { String(localized: "ios.export.peak \(ExportPlanText.stops($0))") }
            ?? String(localized: "ios.export.sdrOnly")
        return [size, String(localized: String.LocalizationValue(plan.gamut.labelKey)), peak].joined(separator: " · ")
    }

    private var destinations: some View {
        Section {
            ForEach(ExportDestination.allCases, id: \.self) { destination in
                // The plan says which destination cannot be chosen yet (Photos
                // before its saving is verified, p7-3c-export §1.3 F).
                let unavailable = model.unavailableReason(destination, editor)?.destinationShortPhrase
                ChoiceRow(symbol: Self.icon(destination), title: Text(Self.name(destination)),
                          detail: unavailable.map { Text(verbatim: $0.text(locale: locale)) } ?? Text(Self.hint(destination)),
                          selected: model.destination == destination) {
                    model.destination = destination
                }
                .disabled(unavailable != nil)
            }
        }
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

    private var encodings: some View {
        Section {
            ForEach(ExportEncoding.allCases, id: \.self) { encoding in
                let selected = model.custom.encoding == encoding
                // The plan's answer for this encoding here (K6).
                let reason = model.unavailableReason(encoding, editor)
                ChoiceRow(symbol: encoding.isSDR ? "photo" : "sun.max", symbolTint: encoding.isSDR ? nil : Color.hdr.amber,
                          title: Text(LocalizedStringKey(encoding.labelKey)),
                          detail: reason.map { Text(verbatim: $0.phrase.text(locale: locale)) } ?? Text(LocalizedStringKey(encoding.hintKey)),
                          detailIsWarning: reason != nil, selected: selected) {
                    model.select(encoding)
                }
                .disabled(reason != nil && !selected)
            }
        } header: {
            Text("ios.export.format")
        } footer: {
            if model.custom.encoding.isSDR { Text("ios.export.sdrNote") }
        }
    }

    private func customControls(_ plan: ExportPlan) -> some View {
        Section {
            // SDR: sRGB or Display P3. Gain maps write Display P3 and
            // BT.2100 Rec. 2020; the format fixes it (F2).
            if plan.gamutIsFixedByFormat || !model.custom.encoding.isSDR {
                LabeledContent {
                    Text(LocalizedStringKey(plan.gamut.labelKey))
                } label: {
                    Text("ios.export.gamut")
                }
            } else {
                Picker(selection: $model.custom.gamut) {
                    ForEach([ExportColorGamut.srgb, .p3], id: \.self) { Text(LocalizedStringKey($0.labelKey)).tag($0) }
                } label: {
                    Text("ios.export.gamut")
                }
            }
            longEdge
            if model.custom.encoding != .sdrTIFF {
                VStack(alignment: .leading, spacing: Space.s1) {
                    LabeledContent {
                        Text(verbatim: String(model.custom.quality)).monospacedDigit()
                    } label: {
                        Text("ios.export.qualityLabel")
                    }
                    Slider(value: Binding(get: { Double(model.custom.quality) },
                                          set: { model.custom.quality = Int($0.rounded()) }), in: 0...100, step: 1)
                }
            }
        }
    }

    /// Original size or a long edge: the presets smaller than the photo, or
    /// a typed number (p7-3c-export §1.3 B).
    @ViewBuilder private var longEdge: some View {
        let photo = model.photoLongEdge(editor)
        Picker(selection: Binding(get: { model.custom.longEdge }, set: { model.setLongEdge($0, photo: photo) })) {
            ForEach(ExportLongEdge.choices(photo: photo, current: model.custom.longEdge), id: \.self) { edge in
                if let edge {
                    Text("ios.export.longEdge.pixels \(String(edge))").tag(Int?.some(edge))
                } else {
                    Text("ios.export.originalSize").tag(Int?.none)
                }
            }
        } label: {
            Text("ios.export.longEdge")
        }
        LabeledContent {
            TextField(value: Binding(get: { model.custom.longEdge }, set: { model.setLongEdge($0, photo: photo) }),
                      format: .number.grouping(.never), prompt: Text("ios.export.originalSize")) {
                Text("ios.export.longEdge.custom")
            }
            // Has a Return key, which commits the number.
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 140)
        } label: {
            Text("ios.export.longEdge.custom")
        }
    }

    /// The frame goes with the export while it is on; the switch here is the
    /// editor's own, so turning it off here turns it off there too.
    private var frameSection: some View {
        Section {
            Toggle(isOn: $frame.isEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ios.frame.title")
                        if frame.isEnabled {
                            Text(frame.style.title).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "photo.artframe")
                }
            }
        } footer: {
            Text("ios.export.frameNote")
        }
    }

    private func primaryLabel(_ plan: ExportPlan?) -> Text {
        switch plan?.handling {
        case .file: Text("ios.export.saveToFiles")
        case .share: Text("ios.export.share")
        case .photoLibrary: Text(verbatim: ExportReasonPhrase.notYetAvailable.text(locale: locale))
        case nil: Text("ios.export.start")
        }
    }

    // MARK: - Running, result, failure

    private func running(_ progress: RecipeExportProgress?) -> some View {
        let fraction: Double? = progress.flatMap { progress in
            guard let done = progress.completedRows, let total = progress.totalRows, total > 0 else { return nil }
            return Double(done) / Double(total)
        }
        return VStack(spacing: Space.s5) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 6)
                if let fraction {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(Color.hdr.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: fraction)
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 96, height: 96)
            VStack(spacing: Space.s2) {
                Text(verbatim: (progress ?? RecipeExportProgress(stage: .preparing)).stageMessage.localized(locale: locale))
                    .font(.headline)
                    .contentTransition(.opacity)
                Text("ios.export.stayInApp")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
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
                Text(verbatim: "\(finished.result.record.name) · \(ExportPlanText.bytes(Int(finished.result.record.byteCount)))")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if let ceiling = IOSExportModel.appliedCeiling(finished.result) {
                Label { Text("ios.export.ceiling \(ExportPlanText.stops(ceiling))") } icon: { Image(systemName: "info.circle") }
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if finished.savedToFiles { Label("ios.export.saved", systemImage: "folder.fill").font(.subheadline) }
            if finished.deliveryFailed { Text("ios.export.deliveryFailed").font(.footnote).foregroundStyle(Color.hdr.warn) }
            Spacer(minLength: 0)
            GlassEffectContainer {
                HStack(spacing: Space.s3) {
                    Button { model.presentingFileExporter = true } label: {
                        Label("ios.export.saveToFiles", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    ShareLink(item: finished.file) {
                        Label("ios.export.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
            }
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Button("ios.export.done") { model.reset() }
                } else {
                    Button { model.reset() } label: { Text("ios.export.retry").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                }
            }
            .controlSize(.large)
        }
        .padding(Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A selectable row: a symbol, a name and a line under it, a checkmark when chosen.
private struct ChoiceRow: View {
    let symbol: String
    var symbolTint: Color? = nil
    let title: Text
    let detail: Text
    var detailIsWarning = false
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(symbolTint ?? Color.secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.body.weight(.medium)).foregroundStyle(.primary)
                    detail.font(.footnote).foregroundStyle(detailIsWarning ? Color.hdr.warn : Color.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(selected ? 1 : 0)
            }
            .frame(minHeight: 52)
            .contentShape(.rect)
            .opacity(isEnabled ? 1 : 0.45)
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

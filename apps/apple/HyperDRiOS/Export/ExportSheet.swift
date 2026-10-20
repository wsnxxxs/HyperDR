import HyperDRDesign
import HyperDRKit
import SwiftUI
import UniformTypeIdentifiers

/// The iOS export sheet, minimal (P7-3b-U; p7-adjustments §4.1, §4.4): one
/// column with Destination | Custom Format, the destination rows or the
/// encoding cards, "Will write", and the main button at the foot. Once started
/// the sheet is the progress, then the result with Save to Files and Share, or
/// the failure. While it runs the sheet cannot be swiped away, which keeps the
/// editor locked.
struct ExportSheet: View {
    @Bindable var model: IOSExportModel
    let editor: RecipeEditor
    @Environment(\.dismiss) private var dismiss

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
                            Button("ios.export.done") { dismiss() }
                        }
                    }
                }
        }
        .interactiveDismissDisabled(model.isRunning)
        .presentationDetents([.medium, .large])
        .fileExporter(isPresented: $model.presentingFileExporter, document: exportedFile,
                      contentType: exportedFile?.contentType ?? .image,
                      defaultFilename: exportedFile?.url.lastPathComponent) { model.savedToFiles($0) }
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
            Picker(selection: $model.page) {
                Text("ios.export.page.destination").tag(IOSExportModel.Page.destination)
                Text("ios.export.page.custom").tag(IOSExportModel.Page.custom)
            } label: {
                Text("ios.export.title")
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            if model.page == .destination {
                destinations
                if let plan { willWrite(plan) }
                Button("ios.export.useCustom") { model.useCustomFormat(from: plan) }
            } else {
                encodings
                if let plan { customControls(plan); willWrite(plan) }
            }
            if model.sessionFailure != nil {
                Text("ios.export.unavailable").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.start(editor) } label: {
                primaryLabel(plan).frame(maxWidth: .infinity).padding(.vertical, Space.s1)
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.canStart(plan, editor))
            .padding(Space.s4)
        }
    }

    private var destinations: some View {
        Section {
            ForEach(ExportDestination.allCases, id: \.self) { destination in
                let available = destination != .photos
                Button { model.destination = destination } label: {
                    HStack(spacing: Space.s3) {
                        Image(systemName: Self.icon(destination)).font(.title2).frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.name(destination)).font(.headline)
                            Text(available ? Self.hint(destination) : "ios.export.notYetAvailable")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.destination == destination { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .frame(minHeight: 64)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .accessibilityAddTraits(model.destination == destination ? .isSelected : [])
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Space.s2) {
                ForEach(ExportEncoding.allCases, id: \.self) { encoding in
                    let selected = model.custom.encoding == encoding
                    Button { model.custom.encoding = encoding } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(encoding.labelKey)).font(.subheadline.weight(.semibold))
                            Text(LocalizedStringKey(encoding.hintKey)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .padding(Space.s2)
                        .background(RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if model.custom.encoding.isSDR { Text("ios.export.sdrNote").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func customControls(_ plan: ExportPlan) -> some View {
        Section {
            Picker(selection: $model.custom.gamut) {
                ForEach(ExportColorGamut.allCases, id: \.self) { Text(LocalizedStringKey($0.labelKey)).tag($0) }
            } label: {
                Text("ios.export.gamut")
            }
            .disabled(plan.gamutIsFixedByFormat)
            if model.custom.encoding != .sdrTIFF {
                LabeledContent {
                    Slider(value: Binding(get: { Double(model.custom.quality) },
                                          set: { model.custom.quality = Int($0.rounded()) }), in: 0...100, step: 1)
                        .frame(maxWidth: 200)
                } label: {
                    Text("ios.export.quality \(String(model.custom.quality))")
                }
            }
        }
    }

    /// "Will write": encoding · gamut · size · peak, then the plan's notes.
    private func willWrite(_ plan: ExportPlan) -> some View {
        Section {
            summary(plan).font(.subheadline)
            if let ceiling = IOSExportModel.ceiling(in: plan) {
                Label { Text("ios.export.ceiling \(ExportPlanText.stops(ceiling))") } icon: { Image(systemName: "info.circle") }
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if plan.notices.contains(where: { $0.key == "dest.social.aspect" }) {
                Label("ios.export.socialAspect", systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if !plan.isExecutable {
                Label(plan.blockers.contains { $0.code == "export_memory_exceeded" }
                          ? LocalizedStringKey("ios.export.error.memory") : LocalizedStringKey("ios.export.blocked"),
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("ios.export.willWrite")
        }
    }

    private func summary(_ plan: ExportPlan) -> Text {
        let size = plan.longEdgeLimit == nil || plan.size.longEdge < (plan.longEdgeLimit ?? 0)
            ? String(localized: "ios.export.originalSize")
            : "\(plan.size.width) × \(plan.size.height)"
        let peak = plan.peakStops.map { String(localized: "ios.export.peak \(ExportPlanText.stops($0))") }
            ?? String(localized: "ios.export.sdrOnly")
        let parts = [String(localized: String.LocalizationValue(plan.encoding.labelKey)),
                     String(localized: String.LocalizationValue(plan.gamut.labelKey)), size, peak]
        return Text(verbatim: parts.joined(separator: " · "))
    }

    private func primaryLabel(_ plan: ExportPlan?) -> Text {
        switch plan?.handling {
        case .file: Text("ios.export.saveToFiles")
        case .share: Text("ios.export.share")
        case .photoLibrary: Text("ios.export.notYetAvailable")
        case nil: Text("ios.export.start")
        }
    }

    // MARK: - Running, result, failure

    private func running(_ progress: RecipeExportProgress?) -> some View {
        VStack(spacing: Space.s4) {
            Text(LocalizedStringKey("export.stage.\((progress?.stage ?? .preparing).rawValue)")).font(.headline)
            if let done = progress?.completedRows, let total = progress?.totalRows, total > 0 {
                ProgressView(value: Double(done), total: Double(total))
            } else {
                ProgressView()
            }
            Button("ios.export.cancel", role: .cancel) { model.cancel() }
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func result(_ finished: IOSExportModel.Finished) -> some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
            Text("ios.export.finished").font(.headline)
            Text(verbatim: "\(finished.result.record.name) · \(ExportPlanText.bytes(Int(finished.result.record.byteCount)))")
                .font(.subheadline).foregroundStyle(.secondary)
            if let ceiling = IOSExportModel.appliedCeiling(finished.result) {
                Label { Text("ios.export.ceiling \(ExportPlanText.stops(ceiling))") } icon: { Image(systemName: "info.circle") }
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if finished.savedToFiles { Label("ios.export.saved", systemImage: "folder") .font(.subheadline) }
            if finished.deliveryFailed { Text("ios.export.deliveryFailed").font(.footnote).foregroundStyle(.orange) }
            Button { model.presentingFileExporter = true } label: {
                Label("ios.export.saveToFiles", systemImage: "folder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            ShareLink(item: finished.file) {
                Label("ios.export.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failed(_ failure: IOSExportModel.Failure) -> some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
            Text("ios.export.failed").font(.headline)
            Text(LocalizedStringKey(failure.key)).multilineTextAlignment(.center)
            if let detail = failure.detail {
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("ios.export.retry") { model.reset() }.buttonStyle(.borderedProminent)
        }
        .padding(Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

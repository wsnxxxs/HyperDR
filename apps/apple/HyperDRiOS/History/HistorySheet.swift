import HyperDRDesign
import HyperDRKit
import HyperDRRecipe
import SwiftUI

/// The export history: every version HyperDR keeps (Kit's
/// `exportHistory`, across photos), newest first and by day. A version
/// opens to its picture, what was written and the adjustments it was
/// written with, and can be shared, saved to Files again or deleted.
struct HistorySheet: View {
    let model: IOSExportModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ExportHistoryEntry]?

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    if entries.isEmpty { empty } else { grid(entries) }
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(Text("ios.history.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(for: ExportID.self) { id in
                if let entry = entries?.first(where: { $0.id == id }) {
                    HistoryDetail(model: model, entry: entry) { removed in
                        withAnimation { entries?.removeAll { $0.id == removed } }
                    }
                }
            }
        }
        .task { entries = await model.history() }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("ios.history.empty", systemImage: "clock.arrow.circlepath")
        } description: {
            Text("ios.history.empty.detail")
        }
    }

    private func grid(_ entries: [ExportHistoryEntry]) -> some View {
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.record.createdAt) }
            .sorted { $0.key > $1.key }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s5) {
                ForEach(days, id: \.key) { day, items in
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Self.title(day)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Space.s4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 2)], spacing: 2) {
                            ForEach(items) { entry in
                                NavigationLink(value: entry.id) { HistoryTile(model: model, entry: entry) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, Space.s3)
        }
    }

    /// "Today", "Yesterday", else the date.
    private static func title(_ day: Date) -> Text {
        if Calendar.current.isDateInToday(day) { return Text("ios.history.today") }
        if Calendar.current.isDateInYesterday(day) { return Text("ios.history.yesterday") }
        return Text(day, format: .dateTime.month().day().weekday())
    }
}

/// A square of the version's thumbnail, with the HDR badge when it carries HDR.
private struct HistoryTile: View {
    let model: IOSExportModel
    let entry: ExportHistoryEntry
    @State private var image: UIImage?

    var body: some View {
        Color.primary.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if entry.record.resolvedSnapshot?.ceilingStops != nil {
                    HDRBadge().scaleEffect(0.8, anchor: .bottomLeading).padding(Space.s1)
                }
            }
            .opacity(entry.record.fileAvailable ? 1 : 0.4)
            .contentShape(.rect)
            .task { image = await model.thumbnail(entry) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(entry.photoName) · \(entry.record.createdAt.formatted(date: .abbreviated, time: .shortened))"))
            .accessibilityAddTraits(.isButton)
    }
}

/// One version: the picture, what was written, the adjustments, and Save to
/// Files and Share at the foot.
private struct HistoryDetail: View {
    let model: IOSExportModel
    let entry: ExportHistoryEntry
    let onRemove: (ExportID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var file: URL?
    @State private var picture: UIImage?
    @State private var thumbnail: UIImage?
    @State private var saving = false
    @State private var confirmingDelete = false

    private var record: ExportRecord { entry.record }
    private var resolved: ResolvedExportSnapshot? { record.resolvedSnapshot }

    var body: some View {
        List {
            Section {
                preview
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("ios.history.written") { written }
            adjustments
        }
        .navigationTitle(Text(verbatim: entry.photoName.isEmpty ? record.name : entry.photoName))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("ios.history.delete", systemImage: "trash")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { actions }
        .confirmationDialog(Text("ios.history.delete.confirm"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("ios.history.delete", role: .destructive) {
                Task {
                    guard (try? await model.remove(entry)) != nil else { return }
                    onRemove(entry.id)
                    dismiss()
                }
            }
        } message: {
            Text("ios.history.delete.message")
        }
        .fileExporter(isPresented: $saving, document: file.map { ExportedFile(url: $0) },
                      contentType: file.map { ExportedFile(url: $0).contentType } ?? .image,
                      defaultFilename: suggestedName) { _ in }
        .task {
            thumbnail = await model.thumbnail(entry)
            guard record.fileAvailable, let url = try? await model.stage(entry) else { return }
            file = url
            picture = await Self.picture(url)
        }
    }

    /// The file itself once read (in HDR where the display has headroom),
    /// the small thumbnail until then.
    private var preview: some View {
        Group {
            if let image = picture ?? thumbnail {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .allowedDynamicRange(.high)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)).aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 440)
        .overlay(alignment: .topTrailing) {
            if resolved?.ceilingStops != nil { HDRBadge().padding(Space.s3) }
        }
    }

    @ViewBuilder private var written: some View {
        if !entry.photoName.isEmpty {
            LabeledContent { Text(verbatim: entry.photoName) } label: { Text("ios.history.photo") }
        }
        LabeledContent { Text(record.createdAt, format: .dateTime.year().month().day().hour().minute()) } label: {
            Text("ios.history.date")
        }
        if let resolved {
            LabeledContent {
                Text(LocalizedStringKey(resolved.encoding.labelKey))
            } label: {
                Text("ios.export.format")
            }
            LabeledContent { Text(verbatim: "\(resolved.width) × \(resolved.height)").monospacedDigit() } label: {
                Text("ios.export.longEdge")
            }
            LabeledContent { Text(LocalizedStringKey(resolved.gamut.labelKey)) } label: { Text("ios.export.gamut") }
            LabeledContent {
                if let stops = resolved.ceilingStops {
                    Text("ios.export.peak \(ExportPlanText.stops(stops))")
                } else {
                    Text("ios.export.sdrOnly")
                }
            } label: {
                Text(verbatim: "HDR")
            }
            if resolved.encoding != .sdrTIFF {
                LabeledContent { Text(verbatim: String(resolved.quality)).monospacedDigit() } label: {
                    Text("ios.export.qualityLabel")
                }
            }
        }
        if let snapshot = record.recipeSnapshot {
            LabeledContent { Text(snapshot.frame != nil ? "ios.adjust.on" : "ios.adjust.off") } label: {
                Text("ios.frame.title")
            }
        }
        LabeledContent {
            Text(verbatim: "\(IOSExportModel.transferName(photo: entry.photoName, file: record.name)) · \(ExportPlanText.bytes(Int(record.byteCount)))")
                .lineLimit(1).truncationMode(.middle)
        } label: {
            Text("ios.history.file")
        }
        if !record.fileAvailable {
            Label("ios.history.fileMissing", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Color.hdr.warn)
        }
    }

    /// The adjustments away from their defaults, by group.
    @ViewBuilder private var adjustments: some View {
        let groups = record.recipeSnapshot.map { AdjustmentPanel().groups(for: $0.recipe).filter(\.isModified) } ?? []
        if groups.isEmpty {
            Section("ios.history.adjustments") {
                Text("ios.history.noAdjustments").foregroundStyle(.secondary)
            }
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.modified) { control in
                        LabeledContent { value(control).monospacedDigit() } label: {
                            AdjustmentText.label(control.declaration)
                        }
                    }
                    if group.group == .look, let name = group.lutName {
                        LabeledContent { Text(verbatim: name) } label: { Text(verbatim: "LUT") }
                    }
                } header: {
                    AdjustmentText.group(group.group)
                }
            }
        }
    }

    private func value(_ control: AdjustmentControl) -> Text {
        if control.spec != nil { return Text(verbatim: control.readout(locale: locale)) }
        if control.kind == .bool { return Text(control.isOn ? "ios.adjust.on" : "ios.adjust.off") }
        if let id = control.selectedOption, let option = control.options.first(where: { $0.id == id }) {
            return AdjustmentText.option(option)
        }
        return Text(verbatim: "")
    }

    private var actions: some View {
        GlassEffectContainer {
            HStack(spacing: Space.s3) {
                Button { saving = true } label: {
                    Label("ios.export.saveToFiles", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.primary)
                if let file {
                    ShareLink(item: file) {
                        Label("ios.export.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.hdr.accentFill)
                } else {
                    Button {} label: {
                        Label("ios.export.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.hdr.accentFill)
                }
            }
            .controlSize(.large)
            .disabled(file == nil)
        }
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s2)
    }

    /// The photo's own name with the version's extension.
    private var suggestedName: String? {
        guard let file else { return nil }
        let photo = (entry.photoName as NSString).deletingPathExtension
        return photo.isEmpty ? file.lastPathComponent : photo + "." + file.pathExtension
    }

    /// The file at a preview size, in HDR where it carries HDR.
    nonisolated private static func picture(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            var configuration = UIImageReader.Configuration()
            configuration.prefersHighDynamicRange = true
            configuration.preferredThumbnailSize = CGSize(width: 1600, height: 1600)
            return UIImageReader(configuration: configuration).image(data: data)
        }.value
    }
}

import HyperDRDesign
import HyperDRKit
import PhotosUI
import SwiftUI

/// The iPad's first screen (ipad-studio §4): the system photo library,
/// embedded, and HyperDR's own column beside it — the ways in that are not
/// the library (Files, a drop), the versions exported lately, the LUT library
/// and Settings. Wider than tall, the column stands on the right; otherwise
/// it lies along the foot as a shelf.
///
/// The picker runs out of process and brings its own sidebar (Photos |
/// Collections, albums, media types). Nothing of ours is laid over it: a view
/// under a toolbar has its touches taken by the picker's remote view, so the
/// column and the shelf sit beside it.
struct PadHome: View {
    let session: EditingSession
    @State private var selection: PhotosPickerItem?
    @State private var importingFile = false
    @State private var showingHistory: HistoryRequest?
    @State private var showingSettings = false
    @State private var showingLUTs = false
    /// The export history, newest first; nil until it has been read.
    @State private var history: [ExportHistoryEntry]?
    @State private var dropTargeted = false

    /// The export history, opened at a version or at its grid.
    struct HistoryRequest: Identifiable {
        let selected: ExportID?
        let id = UUID()
    }

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= proxy.size.height && proxy.size.width >= 900
            Group {
                if session.isAvailable {
                    // One layout that changes axis, so turning the iPad keeps
                    // the picker (and where it was scrolled to).
                    let stack = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    stack {
                        library
                        if wide {
                            column
                                .frame(width: 320)
                                .padding(PadMetrics.margin)
                        } else {
                            shelf
                                .padding(.horizontal, PadMetrics.margin)
                                .padding(.bottom, PadMetrics.margin)
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("ios.home.unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("ios.home.unavailable.detail")
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .onChange(of: selection) { _, item in
            // Cleared once used, so picking the same photo again (after a
            // failed load, or after closing it) is a new request too.
            guard let item else { return }
            selection = nil
            session.open(.library(item))
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { session.open(.file(url)) }
        }
        .sheet(item: $showingHistory, onDismiss: refreshHistory) { request in
            HistorySheet(model: session.exports, selected: request.selected, isPage: true)
        }
        .sheet(isPresented: $showingSettings, onDismiss: refreshHistory) {
            SettingsSheet(session: session, isPage: true)
        }
        .sheet(isPresented: $showingLUTs) {
            if let editor = session.editor {
                LUTLibrarySheet(library: session.exports.luts, editor: editor)
                    .environment(\.lookPickerShown, session.exports.luts.previews.shown)
            }
        }
        // An export may have been written while the editor was up.
        .task(id: session.isEditing) { if !session.isEditing { await loadHistory() } }
        .alert(Text(session.openFailureMessage), isPresented: Binding(get: { session.showsOpenFailure }, set: { session.showsOpenFailure = $0 })) {
            Button("ios.common.ok", role: .cancel) {}
        }
    }

    // MARK: - Library

    private var library: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities([.selectionActions])
        .photosPickerAccessoryVisibility(.hidden, edges: .bottom)
        .ignoresSafeArea(edges: .bottom)
        // The provider rather than the photo: the editor comes up as the
        // drop lands and shows the copy arriving.
        .onDrop(of: [.image], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            session.open(.dropped(provider))
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Color.hdr.accent, lineWidth: 3)
                    .padding(Space.s3)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Column

    /// Standing on the right: who we are, the other ways in, the latest
    /// exports, the LUT library.
    private var column: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                identity
                Spacer(minLength: Space.s2)
                settingsButton
            }
            .padding(.bottom, Space.s5)
            openButton
            dropZone
                .padding(.top, Space.s3)
            recentSection
                .padding(.top, Space.s6)
            Spacer(minLength: Space.s4)
            lutRow
        }
        .padding(20)
        .frame(maxHeight: .infinity, alignment: .top)
        .padPanelSurface()
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(verbatim: "Hyper")
                Text(verbatim: "DR").foregroundStyle(Color.hdr.amberGradient)
            }
            .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("ios.settings.tagline")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            Label("ios.settings.title", systemImage: "gearshape")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .keyboardShortcut(",", modifiers: .command)
    }

    private var openButton: some View {
        Button { importingFile = true } label: {
            Label("ios.file.open", systemImage: "folder")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Space.s1)
        }
        .buttonStyle(.glassProminent)
        .tint(Color.hdr.accentFill)
        .controlSize(.large)
        .keyboardShortcut("o", modifiers: .command)
    }

    /// Where a photo dragged from Photos or Files can be dropped; the whole
    /// screen takes it, this says so and lights up while one is over it.
    private var dropZone: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(dropTargeted ? Color.hdr.accent : Color.secondary)
                .symbolEffect(.bounce, value: dropTargeted)
            VStack(alignment: .leading, spacing: 2) {
                Text("ipad.home.drop").font(.subheadline.weight(.medium))
                Text("ipad.home.drop.detail").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropTargeted ? Color.hdr.accent : Color.white.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        .animation(.smooth(duration: 0.2), value: dropTargeted)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("ipad.home.recent").font(.headline)
                Spacer()
                if !recent.isEmpty {
                    Button { showingHistory = HistoryRequest(selected: nil) } label: {
                        HStack(spacing: 2) {
                            Text("ipad.home.all")
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.hdr.accent)
                    .hoverEffect(.highlight)
                }
            }
            if history?.isEmpty == true {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ios.history.empty").font(.subheadline.weight(.medium))
                    Text("ios.history.empty.detail").font(.caption).foregroundStyle(.secondary)
                }
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padRow()
            } else if !recent.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s2), GridItem(.flexible(), spacing: Space.s2)],
                          spacing: Space.s2) {
                    ForEach(recent.prefix(6)) { entry in
                        Button { showingHistory = HistoryRequest(selected: entry.id) } label: {
                            PadExportThumbnail(model: session.exports, entry: entry)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.lift)
                    }
                }
            }
        }
    }

    private var lutRow: some View {
        Button { showingLUTs = true } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "camera.filters")
                    .font(.title3)
                    .foregroundStyle(Color.hdr.accent)
                    .frame(width: 28)
                Text("ios.lut.title").font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: String(session.exports.luts.entries.count))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PadMetrics.inset)
            .frame(height: 52)
            .padRow()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(session.editor == nil)
    }

    // MARK: - Shelf

    /// Lying along the foot: Files, the latest exports in a row, the LUT
    /// library and Settings.
    private var shelf: some View {
        HStack(spacing: Space.s3) {
            Button { importingFile = true } label: {
                Label("ios.file.open", systemImage: "folder")
                    .font(.headline)
                    .padding(.horizontal, Space.s2)
                    .padding(.vertical, Space.s1)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.hdr.accentFill)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            if !recent.isEmpty {
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 40)
                ScrollView(.horizontal) {
                    HStack(spacing: Space.s2) {
                        ForEach(recent.prefix(8)) { entry in
                            Button { showingHistory = HistoryRequest(selected: entry.id) } label: {
                                PadExportThumbnail(model: session.exports, entry: entry)
                                    .frame(width: 56, height: 56)
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.lift)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(height: 56)
                Button { showingHistory = HistoryRequest(selected: nil) } label: {
                    Label("ios.history.title", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            } else {
                // Nothing exported yet: what else the shelf's room is for.
                HStack(spacing: Space.s2) {
                    Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(dropTargeted ? Color.hdr.accent : Color.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("ipad.home.drop").font(.subheadline.weight(.medium))
                        Text("ipad.home.drop.detail").font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
                .padding(.leading, Space.s2)
                Spacer(minLength: 0)
            }
            Button { showingLUTs = true } label: {
                Label("ios.lut.title", systemImage: "camera.filters")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(session.editor == nil)
            settingsButton
        }
        .padding(Space.s3)
        .padPanelSurface(cornerRadius: 26)
    }

    // MARK: - History

    private func refreshHistory() {
        Task { await loadHistory() }
    }

    private func loadHistory() async {
        history = await session.exports.history()
    }

    /// The versions to show; none until the history has been read.
    private var recent: [ExportHistoryEntry] { history ?? [] }
}

/// A square of an exported version's thumbnail, with the HDR badge when it
/// carries HDR; dimmed when its file is gone.
struct PadExportThumbnail: View {
    let model: IOSExportModel
    let entry: ExportHistoryEntry
    @State private var image: UIImage?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill().transition(.opacity) }
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if entry.record.resolvedSnapshot?.ceilingStops != nil {
                    HDRBadge().scaleEffect(0.75, anchor: .bottomLeading).padding(5)
                }
            }
            .opacity(entry.record.fileAvailable ? 1 : 0.4)
            .contentShape(.rect)
            .animation(.smooth(duration: 0.2), value: image != nil)
            .task(id: entry.id) { image = await model.thumbnail(entry) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(entry.photoName) · \(entry.record.createdAt.formatted(date: .abbreviated, time: .shortened))"))
            .accessibilityAddTraits(.isButton)
    }
}

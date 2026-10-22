import HyperDRDesign
import PhotosUI
import SwiftUI

/// The first screen: the system photo library, embedded. HyperDR has no
/// library of its own and keeps no edits between photos: one tap on a photo
/// opens it in the editor, closing the editor comes back here. The picker
/// runs out of process, needs no access to the library and brings its own
/// Photos | Collections switch (Collections holds albums and media types, so
/// there is no filter of ours). Where that switch sits is the picker's:
/// centred in its top row at compact width, at the top of its sidebar at
/// regular width; no API moves it or picks its tab.
///
/// Settings is the one button at the top trailing corner, a layer in the
/// picker's own top row. The picker's search is turned off: at regular width
/// its field would take that corner (and iPhone's picker shows none there).
///
/// Our two ways in sit in one glass bar at the bottom, named rather than
/// iconic: Open from Files, and Exports (the versions HyperDR wrote) once
/// there is one. On iPad a photo can also be dropped onto the screen from
/// Photos or Files. The bar is a layer over the picker, not a toolbar: a
/// toolbar lets the content run under the bar, and the picker's remote view
/// would then take the bar's touches (on iPad in landscape it took them all).
struct HomeScreen: View {
    let session: EditingSession
    @State private var selection: PhotosPickerItem?
    @State private var importingFile = false
    @State private var showingHistory = false
    @State private var hasHistory = false
    @State private var showingSettings = false
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if session.isAvailable {
                library
                    .overlay(alignment: .bottom) { bar }
                    .overlay(alignment: .topTrailing) { settingsButton }
            } else {
                ContentUnavailableView {
                    Label("ios.home.unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("ios.home.unavailable.detail")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showingHistory, onDismiss: refreshHistory) {
            HistorySheet(model: session.exports)
        }
        .sheet(isPresented: $showingSettings, onDismiss: refreshHistory) {
            SettingsSheet(session: session)
        }
        // An export may have been written while the editor was up.
        .task(id: session.isEditing) { if !session.isEditing { await loadHistory() } }
        .alert(Text("ios.error.load"), isPresented: Binding(get: { session.showsOpenFailure }, set: { session.showsOpenFailure = $0 })) {
            Button("ios.common.ok", role: .cancel) {}
        }
    }

    private var library: some View {
        PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
            EmptyView()
        }
        .photosPickerStyle(.inline)
        .photosPickerDisabledCapabilities([.selectionActions, .search])
        .photosPickerAccessoryVisibility(.hidden, edges: .bottom)
        .ignoresSafeArea(edges: .bottom)
        // The provider rather than the photo: the editor comes up as the
        // drop lands and shows the copy arriving, instead of nothing at all
        // until a large file (or an iCloud download) has been copied.
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

    /// At the editor toolbar's size: a 44-point glass circle.
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
        .padding(.horizontal, Space.s4)
        // Level with the picker's own switch.
        .padding(.top, 10)
    }

    private var bar: some View {
        GlassEffectContainer(spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Button { importingFile = true } label: {
                    Label("ios.file.open", systemImage: "folder")
                }
                if hasHistory {
                    Button { showingHistory = true } label: {
                        Label("ios.history.title", systemImage: "clock.arrow.circlepath")
                    }
                    .transition(.opacity.combined(with: .scale(0.9)))
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .foregroundStyle(.primary)
            .font(.subheadline.weight(.semibold))
        }
        .padding(.bottom, Space.s2)
        .animation(.smooth, value: hasHistory)
    }

    private func refreshHistory() {
        Task { await loadHistory() }
    }

    private func loadHistory() async {
        hasHistory = await !session.exports.history().isEmpty
    }
}

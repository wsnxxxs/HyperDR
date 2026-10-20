import HyperDRDesign
import HyperDRKit
import SwiftUI

/// The LUT library (F8): what is in it, with the import from Files in the
/// toolbar, failures at the top, and removal by swiping. A look chooses from
/// it in the editor's Look group.
struct LUTLibrarySheet: View {
    let library: IOSLUTLibrary
    let editor: RecipeEditor
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !library.failures.isEmpty {
                    Section {
                        ForEach(library.failures, id: \.self) { failure in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(failure.name.isEmpty ? String(localized: "ios.lut.failed") : failure.name)
                                    if let detail = failure.detail {
                                        Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.hdr.warn)
                            }
                        }
                    } header: {
                        Text("ios.lut.failed")
                    }
                }
                if !library.entries.isEmpty {
                    Section {
                        ForEach(library.entries) { entry in
                            HStack(spacing: Space.s3) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LUTSwatches.colour(entry.contentHash).gradient)
                                    .frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: entry.name)
                                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if editor.recipe.activeLook?.contentHash == entry.contentHash {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let entries = offsets.map { library.entries[$0] }
                            Task { for entry in entries { await library.remove(entry) } }
                        }
                    } footer: {
                        Text("ios.lut.footer")
                    }
                }
            }
            .overlay {
                if library.entries.isEmpty, library.failures.isEmpty {
                    ContentUnavailableView {
                        Label("ios.lut.empty.title", systemImage: "camera.filters")
                    } description: {
                        Text("ios.lut.empty")
                    } actions: {
                        Button("ios.lut.import") { importing = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle(Text("ios.lut.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: {
                        Label("ios.lut.import", systemImage: "plus")
                    }
                    .disabled(library.isBusy)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { await library.importLUTs(urls, into: editor) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

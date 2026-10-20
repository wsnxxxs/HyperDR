import HyperDRDesign
import HyperDRKit
import SwiftUI

/// The LUT library as a plain list (F8): what is in it, import failures,
/// and removal. A first, functional version; the design comes later.
struct LUTLibrarySheet: View {
    let library: IOSLUTLibrary
    let editor: RecipeEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !library.failures.isEmpty {
                    Section {
                        ForEach(library.failures, id: \.self) { failure in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.name.isEmpty ? String(localized: "ios.lut.failed") : failure.name)
                                if let detail = failure.detail {
                                    Text(verbatim: detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("ios.lut.failed")
                    }
                }
                Section {
                    if library.entries.isEmpty {
                        Text("ios.lut.empty").foregroundStyle(.secondary)
                    }
                    ForEach(library.entries) { entry in
                        Text(verbatim: entry.name)
                    }
                    .onDelete { offsets in
                        let entries = offsets.map { library.entries[$0] }
                        Task { for entry in entries { await library.remove(entry) } }
                    }
                } footer: {
                    Text("ios.lut.footer")
                }
            }
            .navigationTitle(Text("ios.lut.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("ios.export.done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}

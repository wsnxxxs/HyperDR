import HyperDRDesign
import HyperDRKit
import HyperDRRecipe
import SwiftUI

/// The LUT library (F8) as a sheet from the editor: the list in its own
/// navigation stack, with a close button.
struct LUTLibrarySheet: View {
    let library: IOSLUTLibrary
    let editor: RecipeEditor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LUTLibraryList(library: library, editor: editor)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// What is in the LUT library, with the import from Files in the toolbar,
/// failures at the top, and removal by swiping. A look chooses from it in
/// the editor's Look group. Pushed by Settings, wrapped by the sheet.
struct LUTLibraryList: View {
    let library: IOSLUTLibrary
    let editor: RecipeEditor
    @State private var importing = false

    var body: some View {
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
                                LUTSpacesMenu(entry: entry,
                                              setInput: { library.update(entry.id, input: $0) },
                                              setOutput: { library.update(entry.id, output: $0) })
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
}

/// A library LUT's input and output spaces, as a menu under its name. They
/// are where the look's own spaces start when the LUT is chosen; a camera Log
/// input only takes effect on a RAW photo (elsewhere the look's input stays
/// at its default). Names are the look group's (`look.input`, `look.output`).
private struct LUTSpacesMenu: View {
    let entry: LUTEntry
    /// Each side is set alone; the library keeps the other as it is now.
    let setInput: (LUTSpace) -> Void
    let setOutput: (LUTSpace) -> Void

    var body: some View {
        Menu {
            picker("look.input", selection: entry.input, choose: setInput)
            picker("look.output", selection: entry.output, choose: setOutput)
        } label: {
            HStack(spacing: 4) {
                name("look.input", entry.input)
                Image(systemName: "arrow.right").imageScale(.small)
                name("look.output", entry.output)
            }
            .font(.caption)
        }
    }

    private func option(_ id: String, _ space: LUTSpace) -> ParameterOption? {
        HyperDRRecipe.Adjustments.declaration(id)?.options.first { $0.id == space.rawValue }
    }

    private func name(_ id: String, _ space: LUTSpace) -> Text {
        option(id, space).map(AdjustmentText.option) ?? Text(verbatim: space.rawValue)
    }

    @ViewBuilder private func picker(_ id: String, selection: LUTSpace, choose: @escaping (LUTSpace) -> Void) -> some View {
        if let declaration = HyperDRRecipe.Adjustments.declaration(id) {
            Picker(selection: Binding(get: { selection }, set: choose)) {
                ForEach(AdjustmentText.LookSpaceFamily.allCases, id: \.self) { family in
                    Section {
                        ForEach(LUTSpace.allCases.filter { AdjustmentText.LookSpaceFamily($0.rawValue) == family }, id: \.self) { space in
                            name(id, space).tag(space)
                        }
                    } header: {
                        family.title
                    }
                }
            } label: {
                AdjustmentText.label(declaration)
            }
            .pickerStyle(.menu)
        }
    }
}

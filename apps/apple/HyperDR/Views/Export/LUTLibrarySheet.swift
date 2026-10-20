import SwiftUI
import UniformTypeIdentifiers
import HyperDRDesign

/// The LUT library (M3 §12.1): every look the app keeps, for any photo.
/// Import `.cube` files, search, set a look's spaces, remove one. Browsing
/// stays on while an export runs; importing and removing wait for it.
struct LUTLibrarySheet: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var isPickingFiles = false
    @State private var importCount = 0
    @State private var importedCount: Int?
    @State private var removing: LUTItem?
    @State private var spacesFor: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.lut.library.isEmpty { empty } else { list }
            Divider()
            footer
        }
        .frame(width: 560)
        .frame(minHeight: 340, maxHeight: 620)
        .background(Color.hdr.surfacePanel)
        .fileImporter(isPresented: $isPickingFiles, allowedContentTypes: Self.cubeTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            let before = model.lut.library.count
            importCount = urls.count
            importedCount = nil
            Task {
                await model.importLUTs(urls)
                importedCount = max(0, model.lut.library.count - before)
            }
        }
        .alert(Text("lut.library.removeTitle \(removing?.name ?? "")"), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
            Button("lut.library.remove", role: .destructive) { model.removeLUT(item.id) }
            Button("export.action.cancel", role: .cancel) {}
        } message: { _ in
            Text("lut.library.removeMessage")
        }
    }

    static let cubeTypes: [UTType] = [UTType(filenameExtension: "cube") ?? .data]

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("lut.library.title").font(Font.hdr.title).foregroundStyle(Color.hdr.inkStrong)
                if !model.lut.library.isEmpty {
                    Text("lut.library.count \(model.lut.library.count.formatted(.number.locale(locale)))")
                        .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                }
            }
            HStack(spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.hdr.inkMuted).accessibilityHidden(true)
                    TextField("lut.library.search", text: $query).textFieldStyle(.plain)
                }
                .padding(.horizontal, Space.s2).frame(height: ControlMetrics.compact)
                .background(Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.sm))
                Button { isPickingFiles = true } label: { Label("lut.library.import", systemImage: "plus") }
                    .buttonStyle(HDRButtonStyle(.secondary, height: ControlMetrics.compact))
                    .disabled(model.lut.importBlockerKey != nil || model.lut.isBusy)
            }
            notices
        }
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s4)
    }

    @ViewBuilder private var notices: some View {
        if let key = model.lut.importBlockerKey {
            InspectorNotice(Text(LocalizedStringKey(key)), style: .info)
        } else if model.lut.isBusy && importCount > 0 {
            HStack(spacing: Space.s2) {
                ProgressView().controlSize(.small)
                Text("lut.library.importing \(importCount.formatted(.number.locale(locale)))")
                    .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            }
        } else if !model.lut.failures.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let importedCount, importedCount > 0 {
                    Text("lut.library.importResult \(importedCount.formatted(.number.locale(locale)))")
                }
                ForEach(model.lut.failures) { failure in
                    // The model keeps the file name, and only the name, in `detail`: it
                    // leads the line, so the sentence is worded without the detail block.
                    let body = ErrorText(UserFacingError(code: failure.code, variant: failure.variant)).body(locale: locale)
                    Text(verbatim: failure.detail.map { AppStrings.format("lut.library.failure %@ %@", locale: locale, $0, body) } ?? body)
                }
            }
            .font(Font.hdr.caption).foregroundStyle(Color.hdr.ink)
            .padding(Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hdr.warnSoft, in: .rect(cornerRadius: Radius.sm))
        } else if let importedCount, importedCount > 0 {
            InspectorNotice(Text("lut.library.importResult \(importedCount.formatted(.number.locale(locale)))"), style: .success)
        }
    }

    // MARK: List

    private var matches: [LUTItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? model.lut.library : model.lut.library.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    @ViewBuilder private var list: some View {
        if matches.isEmpty {
            Text("lut.library.noResults \(query)")
                .font(Font.hdr.control).foregroundStyle(Color.hdr.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Space.s6)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(matches) { item in
                        LUTLibraryRow(name: item.name, spaces: Text(verbatim: LUTSpaces.string(item, locale: locale)),
                                      size: item.byteCount.formatted(.byteCount(style: .file).locale(locale)),
                                      isInUse: model.lut.selection?.id == item.id,
                                      onSpaces: { spacesFor = item.id }, onRemove: { removing = item })
                            .popover(isPresented: Binding(get: { spacesFor == item.id },
                                                          set: { if !$0, spacesFor == item.id { spacesFor = nil } }),
                                     arrowEdge: .trailing) { LUTSpacesPopover(model: model, id: item.id) }
                            .padding(.horizontal, Space.s5)
                        Divider()
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "swatchpalette").font(.system(size: 34, weight: .light)).foregroundStyle(Color.hdr.inkDisabled)
            Text("lut.library.empty.title").font(Font.hdr.heading).foregroundStyle(Color.hdr.inkStrong)
            Text("lut.library.empty.message")
                .font(Font.hdr.control).foregroundStyle(Color.hdr.inkMuted)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("lut.library.empty.action") { isPickingFiles = true }
                .buttonStyle(.hdrPrimary)
                .disabled(model.lut.importBlockerKey != nil || model.lut.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(Space.s6)
    }

    private var footer: some View {
        HStack {
            Text("lut.library.footer").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            Spacer(minLength: Space.s3)
            Button("export.action.done") { dismiss() }
                .buttonStyle(.hdrPrimary).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
    }
}

enum LUTSpaces {
    /// "sRGB → Display P3".
    static func string(_ item: LUTItem, locale: Locale) -> String {
        AppStrings.string("choice.lutInput.\(item.input.rawValue)", locale: locale) + " → "
            + AppStrings.string("choice.lutOutput.\(item.output.rawValue)", locale: locale)
    }
}

/// The popover that sets a library look's input and output spaces (M3
/// §12.3). S-Log3 input is for RAW photos only; other photos see it dimmed.
/// The recipe's own spaces are the inspector's (`look.input`, `look.output`).
struct LUTSpacesPopover: View {
    let model: EditorModel
    let id: String

    private var item: LUTItem? { model.lut.library.first { $0.id == id } }

    private var isRAW: Bool { model.document?.formatLabel == "RAW" }
    @Environment(\.locale) private var locale

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("lut.space.note")
                    .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // A setter reads the model's expected spaces when it runs, not the
                // ones this body saw, so two quick changes keep both choices.
                row("lut.space.input", selection: Binding(get: { item.input }, set: { newInput in
                    let live = self.item ?? item
                    model.setLibraryLUTSpaces(id, input: newInput,
                                              output: newInput == .slog3SGamut3Cine ? .rec709 : live.output)
                })) { space in
                    let name = AppStrings.string("choice.lutInput.\(space.rawValue)", locale: locale)
                    return Text(verbatim: space == .slog3SGamut3Cine && !isRAW
                                ? name + " · " + AppStrings.string("lut.space.rawOnly", locale: locale) : name)
                }
                row("lut.space.output", selection: Binding(get: { item.output }, set: {
                    model.setLibraryLUTSpaces(id, input: (self.item ?? item).input, output: $0)
                })) { Text(verbatim: AppStrings.string("choice.lutOutput.\($0.rawValue)", locale: locale)) }
            }
            .padding(Space.s4)
            .frame(width: 290)
            .disabled(model.isEditingLocked)
        }
    }

    private func row(_ title: LocalizedStringKey, selection: Binding<LUTColorSpace>,
                     label: @escaping (LUTColorSpace) -> Text) -> some View {
        HStack {
            Text(title).font(Font.hdr.control).foregroundStyle(Color.hdr.ink)
            Spacer()
            Picker(title, selection: selection) {
                ForEach(LUTColorSpace.allCases, id: \.self) { space in
                    label(space).tag(space)
                        .disabled(space == .slog3SGamut3Cine && !isRAW && selection.wrappedValue != space)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

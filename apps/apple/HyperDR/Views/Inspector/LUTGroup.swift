import SwiftUI
import HyperDRDesign

/// The colour LUT group (M3 §12.2): choose a look from the library, switch
/// it on or off, set its strength and its spaces. A look whose spaces cannot
/// work together stays chosen but does nothing, and the group says why.
struct LUTGroup: View {
    let model: EditorModel
    let window: EditorWindowState

    @State private var isExpanded: Bool

    init(model: EditorModel, window: EditorWindowState, startsExpanded: Bool = false) {
        self.model = model; self.window = window
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        ParameterGroup("lut.title", systemImage: "swatchpalette",
                       summary: model.lut.selection.map { Text(verbatim: $0.name) }, isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: Space.s4) {
                if model.lut.library.isEmpty && model.lut.selection == nil {
                    emptyLibrary
                } else {
                    chooser
                    if let selection = model.lut.selection { selected(selection) }
                }
            }
            .padding(.top, Space.s3)
        }
    }

    // MARK: Empty

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("lut.group.emptyLibrary")
                .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("lut.group.openLibrary") { window.showsLUTLibrary = true }
                .buttonStyle(.hdrSecondary)
        }
    }

    // MARK: Choice

    /// The looks as the menu lists them: the library, and the photo's own
    /// look when it has been removed from the library since.
    private var choices: [LUTItem] {
        var items = model.lut.library
        if let selection = model.lut.selection, !items.contains(where: { $0.id == selection.id }) { items.append(selection) }
        return items
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Picker("lut.select", selection: Binding(get: { model.lut.selection?.id ?? "" },
                                                        set: { model.selectLUT($0.isEmpty ? nil : $0) })) {
                    Text("lut.none").tag("")
                    ForEach(choices) { Text(verbatim: $0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(model.isEditingLocked)
                if model.lut.isBusy { ProgressView().controlSize(.small) }
                if model.lut.selection != nil {
                    Button { model.selectLUT(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.hdrIcon)
                        .help(Text("lut.none"))
                        .accessibilityLabel(Text("lut.none"))
                        .disabled(model.isEditingLocked)
                }
            }
            Button("lut.group.openLibrary") { window.showsLUTLibrary = true }
                .buttonStyle(.hdrCompact(.link))
        }
    }

    // MARK: Selected

    @ViewBuilder private func selected(_ item: LUTItem) -> some View {
        let issue = model.lut.spaceIssueKey
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack {
                Text("lut.enabled").font(Font.hdr.control).foregroundStyle(Color.hdr.ink)
                Spacer(minLength: Space.s2)
                Toggle("lut.enabled", isOn: Binding(get: { model.lut.isEnabled }, set: { model.setLUTEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .disabled(model.isEditingLocked)
            ControlSlider(model: model, key: "lutStrength")
                .disabled(issue != nil)
            LUTSpacesRow(model: model, item: item, isWarning: issue != nil)
            if let issue {
                InspectorNotice(Text(LocalizedStringKey(issue)), style: .warning)
            }
        }
    }
}

/// "Spaces  sRGB → sRGB  Change…": what the look's input and output are, and
/// the popover that sets them.
struct LUTSpacesRow: View {
    let model: EditorModel
    let item: LUTItem
    var isWarning = false

    @State private var showsSpaces = false
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("lut.group.spaces").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            Text(verbatim: LUTSpaces.string(item, locale: locale))
                .font(Font.hdr.readout)
                .foregroundStyle(isWarning ? Color.hdr.warn : Color.hdr.ink)
            Spacer(minLength: 0)
            Button("lut.group.change") { showsSpaces = true }
                .buttonStyle(.hdrCompact(.link))
                .popover(isPresented: $showsSpaces, arrowEdge: .bottom) { LUTSpacesPopover(model: model, id: item.id) }
        }
    }
}

enum LUTSpaces {
    /// "sRGB → Display P3".
    static func string(_ item: LUTItem, locale: Locale) -> String {
        AppStrings.string("choice.lutInput.\(item.input.rawValue)", locale: locale) + " → "
            + AppStrings.string("choice.lutOutput.\(item.output.rawValue)", locale: locale)
    }
}

/// The popover that sets a look's input and output spaces (M3 §12.3).
/// S-Log3 input is for RAW photos only; other photos see it dimmed.
struct LUTSpacesPopover: View {
    let model: EditorModel
    let id: String

    private var item: LUTItem? {
        model.lut.selection?.id == id ? model.lut.selection : model.lut.library.first { $0.id == id }
    }

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
                    if model.lut.selection?.id == id { model.setLUTInput(newInput) }
                    else {
                        let live = self.item ?? item
                        model.setLibraryLUTSpaces(id, input: newInput,
                                                  output: newInput == .slog3SGamut3Cine ? .rec709 : live.output)
                    }
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

import SwiftUI
import HyperDRDesign

/// The Settings window (M3 §11): General, Export and About. Every change
/// applies at once, through `EditorModel.updatePreferences`.
struct SettingsView: View {
    let model: EditorModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
            ExportSettings(model: model)
                .tabItem { Label("settings.tab.export", systemImage: "square.and.arrow.up") }
            AboutSettings(model: model)
                .tabItem { Label("settings.tab.about", systemImage: "info.circle") }
        }
        .frame(width: 520)
        .scenePadding()
    }
}

/// A preference's change as the editor takes it: copy, edit, hand back.
private func change(_ model: EditorModel, _ edit: (inout Preferences) -> Void) {
    var value = model.preferences.value
    edit(&value)
    model.updatePreferences(value)
}

// MARK: - General

private struct GeneralSettings: View {
    let model: EditorModel

    var body: some View {
        Form {
            Section("settings.scopes") {
                Picker("settings.histogramDefault", selection: Binding(
                    get: { model.preferences.value.histogramRGB },
                    set: { rgb in
                        change(model) { $0.histogramRGB = rgb }
                        ViewerSessionState.shared.scopeChannels = rgb ? .rgb : .luma
                    })) {
                    Text("settings.histogram.luma").tag(false)
                    Text("settings.histogram.rgb").tag(true)
                }
                Toggle("settings.highlightZebra", isOn: Binding(get: { model.preferences.value.highlightZebra },
                                                               set: { on in change(model) { $0.highlightZebra = on } }))
                Toggle("settings.shadowZebra", isOn: Binding(get: { model.preferences.value.shadowZebra },
                                                            set: { on in change(model) { $0.shadowZebra = on } }))
            }
            Section("settings.viewing") {
                Picker("settings.initialView", selection: Binding(get: { model.preferences.value.initialView },
                                                                  set: { view in change(model) { $0.initialView = view } })) {
                    Text("settings.initialView.edited").tag(Preferences.InitialView.edited)
                    Text("settings.initialView.original").tag(Preferences.InitialView.original)
                }
            }
            Section {
                Text("settings.immediate").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Export

private struct ExportSettings: View {
    let model: EditorModel

    @State private var isPickingFolder = false

    private var folderLabel: Text {
        model.preferences.exportFolder.label.isEmpty
            ? Text("settings.folderUnset") : Text(verbatim: model.preferences.exportFolder.label)
    }

    var body: some View {
        Form {
            Section("settings.output") {
                Toggle("settings.rememberOutput", isOn: Binding(get: { model.preferences.value.rememberOutput },
                                                               set: { on in change(model) { $0.rememberOutput = on } }))
                Text("settings.rememberOutputNote").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            }
            Section("settings.saving") {
                Picker("settings.saveMode", selection: Binding(get: { model.preferences.value.saveMode },
                                                               set: { mode in change(model) { $0.saveMode = mode } })) {
                    Text("settings.saveMode.ask").tag(Preferences.SaveMode.ask)
                    Text("settings.saveMode.folder").tag(Preferences.SaveMode.folder)
                }
                Text("settings.saveModeNote").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                LabeledContent("settings.folder") {
                    HStack {
                        folderLabel.foregroundStyle(Color.hdr.inkMuted)
                        Button("settings.change") { isPickingFolder = true }
                        Button("settings.openInFinder") { Task { await model.revealExportFolder() } }
                            .disabled(!model.preferences.exportFolder.ready)
                    }
                }
                Text("settings.folderNote").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                if let failure = model.preferences.failure {
                    Text(verbatim: ErrorText(failure).body).font(Font.hdr.caption).foregroundStyle(Color.hdr.danger)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await model.setExportFolder(url) } }
        }
    }
}

// MARK: - About

struct AboutSettings: View {
    let model: EditorModel

    @Environment(\.locale) private var locale
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: Space.s3) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "HyperDR").font(Font.hdr.heading)
                        Text("settings.version \(model.aboutInformation.version) \(model.aboutInformation.buildNumber)")
                            .font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
                    }
                }
            }
            Section("settings.diagnostics") {
                ForEach(rows, id: \.key) { row in
                    LabeledContent(LocalizedStringKey(row.key)) { Text(verbatim: row.value).multilineTextAlignment(.trailing).textSelection(.enabled) }
                }
                HStack {
                    Button("settings.copyDiagnostics") {
                        // The equivalent command is built on demand from one snapshot of the edit.
                        Task {
                            let text = await model.diagnosticText
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                    if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
                        Button("settings.acknowledgements") { NSWorkspace.shared.open(notices) }
                    }
                }
            }
            Section {
                Button("settings.reset", role: .destructive) { confirmsReset = true }
                Text("settings.resetNote").font(Font.hdr.caption).foregroundStyle(Color.hdr.inkMuted)
            }
        }
        .formStyle(.grouped)
        .alert("settings.resetTitle", isPresented: $confirmsReset) {
            Button("settings.resetConfirm", role: .destructive) { model.resetPreferences() }
            Button("export.action.cancel", role: .cancel) {}
        } message: {
            Text("settings.resetMessage")
        }
    }

    /// The read-only rows: the engine, the AI models, HEVC encoding, the export
    /// memory limit, this display and its HDR preview, what the app opens and
    /// this Mac.
    private var rows: [(key: String, value: String)] {
        var rows = [("settings.diag.engine", SettingsDiagnostics.engine(model, locale: locale)),
                    ("settings.diag.model", SettingsDiagnostics.models(model, locale: locale)),
                    ("settings.diag.hevc", SettingsDiagnostics.hevc(model, locale: locale))]
        if let budget = SettingsDiagnostics.memoryBudget(model, locale: locale) { rows.append(("settings.diag.memory", budget)) }
        rows += [("settings.diag.display", SettingsDiagnostics.display(model.display, locale: locale)),
                 ("settings.diag.preview", SettingsDiagnostics.preview(model.display, locale: locale))]
        // Only while a RAW is open: the decoder and system build that developed it.
        if let raw = SettingsDiagnostics.raw(model, locale: locale) { rows.append(("settings.diag.raw", raw)) }
        rows += [("settings.diag.opens", SettingsDiagnostics.opens(model)),
                 ("settings.diag.machine", SettingsDiagnostics.machine(locale: locale))]
        return rows
    }
}

/// The About page's diagnostic values as plain strings.
enum SettingsDiagnostics {
    /// "Ready · version 1.0 · interface 3", or why the engine is not.
    static func engine(_ model: EditorModel, locale: Locale) -> String {
        switch model.engine {
        case .starting: return AppStrings.string("settings.diag.engine.starting", locale: locale)
        case .failed(let error):
            return AppStrings.format("settings.diag.engine.failed %@", locale: locale, ErrorText(error).title(locale: locale))
        case .ready(let version):
            return AppStrings.format("settings.diag.engine.ready %@ %@", locale: locale, version,
                                     model.aboutInformation.engineABI.map { String($0) } ?? "—")
        }
    }

    /// The models this build can run, each with the version the engine reports;
    /// why none can run when the runtime is missing; "None" when it is there
    /// but offers nothing.
    static func models(_ model: EditorModel, locale: Locale) -> String {
        let table = model.services.modelTable()
        guard table.runtimeReady else { return AppStrings.string("settings.diag.model.noRuntime", locale: locale) }
        let names = table.models.filter(\.isEnabled).map { choice in
            let name = AppStrings.string(choice.nameKey, locale: locale)
            guard let version = shortVersion(choice.version) else { return name }
            return AppStrings.format("settings.diag.model.version %@ %@", locale: locale, name, version)
        }
        // No model enabled: say so, rather than leave an empty (and taller) row.
        guard !names.isEmpty else { return AppStrings.string("export.summary.none", locale: locale) }
        return names.formatted(.list(type: .and, width: .narrow).locale(locale))
    }

    /// "v1" from the engine's "research-demo-fold0-seed908/v1": the part after
    /// the last slash; the whole string when there is none. The full version is
    /// in the copied diagnostics.
    static func shortVersion(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        let last = version.split(separator: "/").last.map(String.init) ?? version
        return last.isEmpty ? version : last
    }

    /// "12 GB": the engine's export memory budget; nil when it reports none.
    static func memoryBudget(_ model: EditorModel, locale: Locale) -> String? {
        guard let bytes = model.aboutInformation.memoryBudgetBytes, bytes > 0 else { return nil }
        return memory(bytes, locale: locale)
    }

    static func memory(_ bytes: UInt64, locale: Locale) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }

    /// "8-bit and 10-bit", "8-bit only" or "Not available".
    static func hevc(_ model: EditorModel, locale: Locale) -> String {
        guard let capabilities = model.exportCapabilities else { return AppStrings.string("settings.diag.hevc.none", locale: locale) }
        return AppStrings.string(capabilities.main10 ? "settings.diag.hevc.both"
                                 : capabilities.main8 ? "settings.diag.hevc.main8" : "settings.diag.hevc.none", locale: locale)
    }

    /// "HDR · headroom 3.2 / 4.0 stops", or "SDR"; the screen's name leads.
    static func display(_ display: DisplayState, locale: Locale) -> String {
        let name = display.screenName.isEmpty ? "" : display.screenName + " · "
        guard display.supportsEDR else { return name + AppStrings.string("settings.diag.sdr", locale: locale) }
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(locale)
        return name + AppStrings.format("settings.diag.hdr %@ %@", locale: locale,
                                        log2(display.currentHeadroom).formatted(number),
                                        log2(display.potentialHeadroom).formatted(number))
    }

    /// "Decoder 8 · macOS build 25A123" from the open RAW's own report. Nothing
    /// without one: the model leaves both nil rather than guess.
    static func raw(_ model: EditorModel, locale: Locale) -> String? {
        let about = model.aboutInformation
        guard let decoder = about.decoderVersion, let build = about.osBuild else { return nil }
        // "8.dng" is decoder 8 on a DNG, said the way the camera group says it.
        let isDNG = decoder.hasSuffix(".dng")
        return AppStrings.format(isDNG ? "settings.diag.rawValueDNG %@ %@" : "settings.diag.rawValue %@ %@", locale: locale,
                                 isDNG ? String(decoder.dropLast(4)) : decoder, build)
    }

    enum PreviewState: String, Equatable {
        case hdr, sdrDisplay = "sdr-display", noHeadroom = "no-headroom"
    }

    /// Whether the canvas can show HDR on this display right now.
    static func previewState(_ display: DisplayState) -> PreviewState {
        guard display.supportsEDR else { return .sdrDisplay }
        return display.currentHeadroom <= 1 ? .noHeadroom : .hdr
    }

    static func preview(_ display: DisplayState, locale: Locale) -> String {
        switch previewState(display) {
        case .hdr: AppStrings.string("settings.diag.preview.hdr", locale: locale)
        case .sdrDisplay: AppStrings.string("settings.diag.preview.sdrDisplay", locale: locale)
        case .noHeadroom: AppStrings.string("settings.diag.preview.noHeadroom", locale: locale)
        }
    }

    /// "macOS 27.0.1": the version only, without the build number.
    static func system() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// "Apple M4 Pro" from the kernel; nil when it will not say.
    static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    /// "macOS 27.0.1 · Apple M4 Pro · 48 GB memory". The pieces are injectable
    /// for tests.
    static func machine(system: String = system(), chip: String? = chipName(),
                        memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory, locale: Locale) -> String {
        let chip = chip ?? AppStrings.string("settings.diag.machine.unknownChip", locale: locale)
        return AppStrings.format("settings.diag.machine.value %@ %@ %@", locale: locale, system, chip,
                                 memory(memoryBytes, locale: locale))
    }

    static func opens(_ model: EditorModel) -> String {
        model.openableContentTypes.flatMap { $0.tags[.filenameExtension] ?? [] }.sorted().map { "." + $0 }.joined(separator: " ")
    }
}

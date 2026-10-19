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

private struct AboutSettings: View {
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
                        Text("settings.version \(Self.version) \(Self.build)")
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

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    /// The read-only rows: the AI models, HEVC encoding, this display, what
    /// the app opens and the system.
    private var rows: [(key: String, value: String)] {
        [("settings.diag.model", SettingsDiagnostics.models(model, locale: locale)),
         ("settings.diag.hevc", SettingsDiagnostics.hevc(model, locale: locale)),
         ("settings.diag.display", SettingsDiagnostics.display(model.display, locale: locale)),
         ("settings.diag.opens", SettingsDiagnostics.opens(model)),
         ("settings.diag.system", ProcessInfo.processInfo.operatingSystemVersionString)]
    }
}

/// The About page's diagnostic values as plain strings.
enum SettingsDiagnostics {
    static func models(_ model: EditorModel, locale: Locale) -> String {
        model.ai.models.filter(\.isEnabled).map { AppStrings.string($0.nameKey, locale: locale) }
            .formatted(.list(type: .and, width: .narrow).locale(locale))
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

    static func opens(_ model: EditorModel) -> String {
        model.openableContentTypes.flatMap { $0.tags[.filenameExtension] ?? [] }.sorted().map { "." + $0 }.joined(separator: " ")
    }
}

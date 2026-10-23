import HyperDRDesign
import HyperDRKit
import SwiftUI

/// Settings, from the library's top trailing button: the app and its
/// version at the top (where the subscription's state and Restore Purchases
/// will go), the LUT library, the export history kept in the app and how
/// much room it takes, diagnostics to send when something goes wrong, and
/// About (version, privacy, acknowledgements).
/// Only what the app really has; nothing here is a placeholder.
///
/// On the iPad Studio (ipad-studio §7) the same sections are a page of two
/// columns, as the system's Settings: who we are and the sections on the
/// left, the chosen section on the right.
struct SettingsSheet: View {
    let session: EditingSession
    /// The iPad Studio's two columns.
    var isPage = false
    @Environment(\.dismiss) private var dismiss
    @State private var history: [ExportHistoryEntry] = []
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var diagnostics: DiagnosticsFile?
    @State private var preparingDiagnostics = false
    @State private var diagnosticsFailed = false
    @State private var page: Page? = .luts

    /// The iPad's sections.
    private enum Page: Hashable { case luts, exports, diagnostics, about }

    var body: some View {
        Group {
            if isPage { split } else { stack }
        }
        .confirmationDialog(Text("ios.settings.history.clear.confirm"), isPresented: $confirmingClear,
                            titleVisibility: .visible) {
            Button("ios.settings.history.clear", role: .destructive) { clear() }
        } message: {
            Text("ios.settings.history.footer")
        }
        .sheet(item: $diagnostics) { file in
            ActivitySheet(items: [file.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert(Text("ios.settings.diagnostics.failed"), isPresented: $diagnosticsFailed) {}
        .task { history = await session.exports.history() }
    }

    private var stack: some View {
        NavigationStack {
            List {
                Section { identity }
                if let editor = session.editor {
                    Section("ios.settings.editing") {
                        NavigationLink {
                            LUTLibraryList(library: session.exports.luts, editor: editor)
                        } label: {
                            LabeledContent {
                                Text(verbatim: String(session.exports.luts.entries.count)).monospacedDigit()
                            } label: {
                                Label("ios.lut.title", systemImage: "camera.filters")
                            }
                        }
                    }
                }
                historySection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle(Text("ios.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
        }
    }

    private var split: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section { identity }
                Section {
                    Label("ios.lut.title", systemImage: "camera.filters")
                        .badge(session.exports.luts.entries.count)
                        .tag(Page.luts)
                    Label("ios.history.title", systemImage: "clock.arrow.circlepath")
                        .badge(history.count)
                        .tag(Page.exports)
                    Label("ipad.settings.diagnostics", systemImage: "stethoscope")
                        .tag(Page.diagnostics)
                    Label("ios.settings.about", systemImage: "info.circle")
                        .tag(Page.about)
                }
            }
            .navigationTitle(Text("ios.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeButton }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(300)
        } detail: {
            NavigationStack {
                Group {
                    switch page ?? .luts {
                    case .luts:
                        if let editor = session.editor {
                            LUTLibraryList(library: session.exports.luts, editor: editor)
                        }
                    case .exports:
                        List { historySection }
                            .navigationTitle(Text("ios.history.title"))
                    case .diagnostics:
                        List { diagnosticsSection }
                            .navigationTitle(Text("ipad.settings.diagnostics"))
                    case .about:
                        List { aboutSection }
                            .navigationTitle(Text("ios.settings.about"))
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .presentationSizing(.page)
    }

    private var closeButton: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
        }
    }

    private var historySection: some View {
        Section {
            LabeledContent {
                if history.isEmpty {
                    Text("ios.settings.history.none")
                } else {
                    Text("ios.settings.history.kept \(String(history.count)) \(ExportPlanText.bytes(keptBytes))")
                        .monospacedDigit()
                }
            } label: {
                Label("ios.history.title", systemImage: "clock.arrow.circlepath")
            }
            Button("ios.settings.history.clear", role: .destructive) { confirmingClear = true }
                .disabled(history.isEmpty || clearing)
        } footer: {
            Text("ios.settings.history.footer")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Button(action: exportDiagnostics) {
                LabeledContent {
                    if preparingDiagnostics { ProgressView() }
                } label: {
                    Label("ios.settings.diagnostics.export", systemImage: "stethoscope")
                }
            }
            .disabled(preparingDiagnostics)
        } footer: {
            Text("ios.settings.diagnostics.footer")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent { Text(verbatim: Self.version).monospacedDigit() } label: {
                Text("ios.settings.version")
            }
            NavigationLink("ios.settings.acknowledgements") { AcknowledgementsView() }
        } header: {
            Text("ios.settings.about")
        } footer: {
            Text("ios.settings.privacy")
        }
    }

    private var identity: some View {
        VStack(spacing: Space.s1) {
            HStack(spacing: 0) {
                Text(verbatim: "Hyper")
                Text(verbatim: "DR").foregroundStyle(isPage ? Color.hdr.amber : Color.primary)
            }
            .font(.title2.weight(.semibold))
            Text("ios.settings.tagline")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s3)
    }

    private var keptBytes: Int {
        history.reduce(0) { $0 + Int($1.record.byteCount) }
    }

    /// Removes every version not still being written, then reads what is left.
    private func clear() {
        clearing = true
        Task {
            for entry in history { try? await session.exports.remove(entry) }
            history = await session.exports.history()
            clearing = false
        }
    }

    /// Writes the diagnostics file, then offers it to share.
    private func exportDiagnostics() {
        preparingDiagnostics = true
        Task {
            do { diagnostics = DiagnosticsFile(url: try await DiagnosticsReport.make()) } catch { diagnosticsFailed = true }
            preparingDiagnostics = false
        }
    }

    /// "1.0.0 (42)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
}

private struct DiagnosticsFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for files made on request, which `ShareLink`
/// cannot wait for.
private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The third-party notices bundled with the app (`THIRD_PARTY_NOTICES.md`):
/// the components with their purpose and licence, then the notes under them.
private struct AcknowledgementsView: View {
    private let notices = Notices.load()

    var body: some View {
        List {
            Section {
                ForEach(notices.components, id: \.name) { component in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: component.name)
                        Text(component.purpose).font(.caption).foregroundStyle(.secondary)
                        Text(component.license).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
            }
            ForEach(notices.notes, id: \.self) { note in
                Section {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("ios.settings.acknowledgements"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private struct Notices {
        struct Component {
            let name: String
            let purpose, license: AttributedString
        }
        var components: [Component] = []
        var notes: [AttributedString] = []

        /// The table's rows and the paragraphs after the title, from the file.
        static func load() -> Notices {
            var notices = Notices()
            guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return notices }
            for block in text.components(separatedBy: "\n\n") {
                let lines = block.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                if lines.first?.hasPrefix("|") == true {
                    for line in lines.dropFirst(2) {
                        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                        guard cells.count >= 3 else { continue }
                        notices.components.append(Component(name: cells[0], purpose: markdown(cells[1]),
                                                            license: markdown(cells[2])))
                    }
                } else if lines.first?.hasPrefix("#") == false, !lines.isEmpty {
                    notices.notes.append(markdown(lines.joined(separator: " ")))
                }
            }
            return notices
        }

        private static func markdown(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text)) ?? AttributedString(text)
        }
    }
}

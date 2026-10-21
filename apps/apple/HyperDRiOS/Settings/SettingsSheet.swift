import HyperDRDesign
import HyperDRKit
import SwiftUI

/// Settings, from the library's top trailing button: the app and its
/// version at the top (where the subscription's state and Restore Purchases
/// will go), the LUT library, the export history kept in the app and how
/// much room it takes, and About (version, privacy, acknowledgements).
/// Only what the app really has; nothing here is a placeholder.
struct SettingsSheet: View {
    let session: EditingSession
    @Environment(\.dismiss) private var dismiss
    @State private var history: [ExportHistoryEntry] = []
    @State private var confirmingClear = false
    @State private var clearing = false

    var body: some View {
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
            .navigationTitle(Text("ios.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .confirmationDialog(Text("ios.settings.history.clear.confirm"), isPresented: $confirmingClear,
                                titleVisibility: .visible) {
                Button("ios.settings.history.clear", role: .destructive) { clear() }
            } message: {
                Text("ios.settings.history.footer")
            }
        }
        .task { history = await session.exports.history() }
    }

    private var identity: some View {
        VStack(spacing: Space.s1) {
            Text(verbatim: "HyperDR")
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

    /// "1.0.0 (42)".
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        guard let build = info?["CFBundleVersion"] as? String, build != short else { return short }
        return "\(short) (\(build))"
    }
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

import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRecipe
import Observation

/// The iOS LUT library (F8): Kit's `LUTLibrary`, installed into the editor
/// so the look group lists it and exports can use it.
///
/// - The library lives in Kit's support directory (Application Support,
///   kept across launches and updates; not `tmp/`).
/// - `fileImporter` URLs go to Kit as they are: `LUTLibrary.importLUT` holds
///   the security scope for the copy itself.
/// - An export applies the look's LUT from the library into the photo's
///   session first; a look whose LUT is not in the library blocks the export
///   before it starts (`missingLook`).
@MainActor @Observable final class IOSLUTLibrary {
    /// One file that could not be imported, or a LUT that could not be read.
    struct Failure: Hashable {
        let name: String
        let detail: String?
    }

    private(set) var entries: [LUTEntry] = []
    private(set) var failures: [Failure] = []
    private(set) var isBusy = false
    /// References of the installed entries, by library id.
    private var references: [String: LUTReference] = [:]
    /// Whether `entries` has been read once.
    private var loaded = false
    @ObservationIgnored private let library: () -> Task<LUTLibrary, any Error>

    init(library: @escaping () -> Task<LUTLibrary, any Error>) {
        self.library = library
    }

    /// The look group's choices, in library order.
    var choices: [LUTReference] { entries.compactMap { references[$0.id.rawValue] } }

    /// The recipe's look when its LUT is not in the library (or not yet in
    /// the editor): the export is blocked with this reason.
    func missingLook(_ editor: RecipeEditor) -> LUTReference? {
        guard let look = editor.recipe.activeLook else { return nil }
        if let missing = editor.missingLook { return missing }
        return loaded && !entries.contains(where: { Self.hash($0.id) == look.contentHash }) ? look : nil
    }

    /// Reads the library and installs what the editor does not have yet.
    func refresh(into editor: RecipeEditor) async {
        guard let library = try? await library().value else { return }
        entries = await library.entries()
        loaded = true
        let missing = entries.filter { references[$0.id.rawValue] == nil }
            .map { LibraryLUT(id: $0.id.rawValue, name: $0.name) }
        let failed = await editor.installLibraryLUTs(missing, cube: { id in
            try await library.cube(try LUTID(rawValue: id))
        }) { id, reference in
            self.references[id] = reference
        }
        failures += failed.map { Failure(name: $0, detail: nil) }
    }

    /// Imports `.cube` files picked in Files, each failure by its file name.
    func importLUTs(_ urls: [URL], into editor: RecipeEditor) async {
        guard !isBusy else { return }
        isBusy = true
        failures = []
        defer { isBusy = false }
        do {
            let library = try await library().value
            for url in urls {
                do { _ = try await library.importLUT(url) } catch {
                    failures.append(Failure(name: url.lastPathComponent, detail: Self.detail(error)))
                }
            }
        } catch {
            failures.append(Failure(name: "", detail: Self.detail(error)))
        }
        await refresh(into: editor)
    }

    /// Removes a LUT from the library. The editor keeps it until relaunch,
    /// but an export of a look on it is blocked from now on.
    func remove(_ entry: LUTEntry) async {
        do {
            try await library().value.remove(entry.id)
            references[entry.id.rawValue] = nil
            entries.removeAll { $0.id == entry.id }
        } catch {
            failures = [Failure(name: entry.name, detail: Self.detail(error))]
        }
    }

    /// The library id of a content hash (`sha256:<hex>`): Kit names a LUT
    /// by the SHA-256 of its file, which is what `ColorLUT` hashes too.
    static func libraryID(_ contentHash: String) throws -> LUTID {
        try LUTID(rawValue: contentHash.hasPrefix("sha256:") ? String(contentHash.dropFirst(7)) : contentHash)
    }

    private static func hash(_ id: LUTID) -> String { "sha256:" + id.rawValue }

    private static func detail(_ error: any Error) -> String {
        (error as? HyperDRError)?.message ?? String(describing: error)
    }
}

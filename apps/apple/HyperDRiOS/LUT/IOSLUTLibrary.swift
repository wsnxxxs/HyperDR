import Foundation
import HyperDRDesign
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
///   session first, even when the look is off: Kit keeps every look the
///   recipe names with the version. A look whose LUT is not in the library
///   blocks the export before it starts (`missingLook`).
@MainActor @Observable final class IOSLUTLibrary {
    /// One file that could not be imported, or a LUT that could not be read.
    struct Failure: Hashable {
        let name: String
        let detail: String?
    }

    private(set) var entries: [LUTEntry] = []
    private(set) var failures: [Failure] = []
    private(set) var isBusy = false
    /// Each LUT on the open photo, for the look pickers and the list.
    let previews = LookPreviews()
    /// References of the installed entries, by library id.
    private var references: [String: LUTReference] = [:]
    /// The latest space write of each LUT; the next one waits for it.
    @ObservationIgnored private var writes: [LUTID: Task<Void, Never>] = [:]
    /// Counts each LUT's space changes, so a failed write knows whether a later one is queued.
    @ObservationIgnored private var writeRevisions: [LUTID: Int] = [:]
    /// Whether `entries` has been read once.
    private var loaded = false
    @ObservationIgnored private let library: () -> Task<LUTLibrary, any Error>

    init(library: @escaping () -> Task<LUTLibrary, any Error>) {
        self.library = library
    }

    /// The look group's choices, in library order.
    var choices: [LUTReference] { entries.compactMap { references[$0.id.rawValue] } }

    /// The spaces the library records for each LUT, by content hash: choosing
    /// a LUT in the look group starts the look's spaces from them.
    var spaces: [String: AdjustmentLookSpaces] {
        Dictionary(entries.map { ($0.contentHash, AdjustmentLookSpaces(input: $0.input.rawValue, output: $0.output.rawValue)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// The library's LUTs with their spaces, for `previews`.
    var looks: [LookPreviews.Look] {
        entries.compactMap { entry in
            references[entry.id.rawValue].map { LookPreviews.Look(reference: $0, input: entry.input.rawValue, output: entry.output.rawValue) }
        }
    }

    /// Chooses an entry as the photo's look, with its spaces; nil for none.
    func choose(_ entry: LUTEntry?, in editor: RecipeEditor) {
        guard let entry else { return editor.chooseLook(nil, input: "", output: "") }
        guard let reference = references[entry.id.rawValue] else { return }
        editor.chooseLook(reference, input: entry.input.rawValue, output: entry.output.rawValue)
    }

    /// Sets a LUT's spaces in the library, and on the look in use.
    func setSpaces(_ id: LUTID, input: LUTSpace? = nil, output: LUTSpace? = nil, in editor: RecipeEditor) {
        update(id, input: input, output: output)
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        editor.adoptLookSpaces(entry.contentHash, input: entry.input.rawValue, output: entry.output.rawValue)
    }

    /// Records the spaces a control chose on the look (`Recipe.chosenLookSpaces`)
    /// for its LUT, so the next choice of it starts from them.
    func record(from old: Recipe, to new: Recipe) {
        guard let chosen = Recipe.chosenLookSpaces(from: old, to: new),
              let entry = entries.first(where: { $0.contentHash == chosen.contentHash }) else { return }
        update(entry.id, input: chosen.input.flatMap(LUTSpace.init(rawValue:)),
               output: chosen.output.flatMap(LUTSpace.init(rawValue:)))
    }

    /// The recipe's look when its LUT is not in the library (or, for a look
    /// in effect, not yet in the editor): the export is blocked with this
    /// reason. A look that is off counts too, since the export copies it.
    func missingLook(_ editor: RecipeEditor) -> LUTReference? {
        guard let look = editor.recipe.look else { return nil }
        if let missing = editor.missingLook { return missing }
        return loaded && !entries.contains(where: { Self.hash($0.id) == look.contentHash }) ? look : nil
    }

    /// Reads the library and installs what the editor does not have yet.
    func refresh(into editor: RecipeEditor) async {
        guard let library = try? await library().value else { return }
        let read = await library.entries()
        // A LUT whose spaces are being written keeps the spaces shown, which
        // are what the pending write will store.
        entries = read.map { entry in
            guard writes[entry.id] != nil, let shown = entries.first(where: { $0.id == entry.id }) else { return entry }
            var kept = entry
            kept.input = shown.input
            kept.output = shown.output
            return kept
        }
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
    /// One file imported with a photo open becomes its look: a LUT is
    /// imported to be used.
    func importLUTs(_ urls: [URL], into editor: RecipeEditor) async {
        guard !isBusy else { return }
        isBusy = true
        failures = []
        defer { isBusy = false }
        var imported: [LUTID] = []
        do {
            let library = try await library().value
            for url in urls {
                do { imported.append(try await library.importLUT(url).id) } catch {
                    failures.append(Failure(name: url.lastPathComponent, detail: Self.detail(error)))
                }
            }
        } catch {
            failures.append(Failure(name: "", detail: Self.detail(error)))
        }
        await refresh(into: editor)
        if urls.count == 1, let id = imported.first, editor.source != nil,
           let entry = entries.first(where: { $0.id == id }) {
            choose(entry, in: editor)
        }
    }

    /// Records one of a LUT's spaces: `input` or `output`, whichever is
    /// given. The recipe's own spaces are the look group's; this only changes
    /// where a later choice starts. The list shows the change at once; writes
    /// for one LUT run one after another, each with the other side as the
    /// list holds it when the write starts, so a quick second change never
    /// puts back the first one's old value.
    func update(_ id: LUTID, input: LUTSpace? = nil, output: LUTSpace? = nil) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let input { entries[index].input = input }
        if let output { entries[index].output = output }
        let previous = writes[id]
        writeRevisions[id, default: 0] &+= 1
        let revision = writeRevisions[id]
        let write = Task { [weak self] in
            await previous?.value
            guard let self, let entry = entries.first(where: { $0.id == id }) else { return }
            do {
                let updated = try await library().value.update(id, input: entry.input, output: entry.output)
                // A newer change made while this one was on disk stays shown.
                if let index = entries.firstIndex(where: { $0.id == id }),
                   entries[index].input == updated.input, entries[index].output == updated.output {
                    entries[index] = updated
                }
            } catch {
                failures = [Failure(name: entry.name, detail: Self.detail(error))]
                // Show what is on disk again, unless a later change is queued:
                // that write stores the latest spaces, or rolls back itself.
                guard writeRevisions[id] == revision else { return }
                if let library = try? await library().value,
                   let stored = await library.entries().first(where: { $0.id == id }),
                   writeRevisions[id] == revision,
                   let index = entries.firstIndex(where: { $0.id == id }) {
                    entries[index] = stored
                }
            }
        }
        writes[id] = write
        Task { [weak self] in
            await write.value
            if self?.writes[id] == write { self?.writes[id] = nil }
        }
    }

    /// Removes a LUT from the library, and the photo's look when it is on
    /// that LUT (one undo step; an undone look stays unexportable until the
    /// LUT is imported again).
    func remove(_ entry: LUTEntry, from editor: RecipeEditor) async {
        do {
            try await library().value.remove(entry.id)
            references[entry.id.rawValue] = nil
            entries.removeAll { $0.id == entry.id }
            editor.dropLook(entry.contentHash)
        } catch {
            failures = [Failure(name: entry.name, detail: Self.detail(error))]
        }
    }

    /// The library id of a content hash (`sha256:<hex>`): Kit names a LUT
    /// by the SHA-256 of its file, which is what `ColorLUT(data:)` hashes too.
    static func libraryID(_ contentHash: String) throws -> LUTID {
        try LUTID(rawValue: contentHash.hasPrefix("sha256:") ? String(contentHash.dropFirst(7)) : contentHash)
    }

    private static func hash(_ id: LUTID) -> String { "sha256:" + id.rawValue }

    private static func detail(_ error: any Error) -> String {
        (error as? HyperDRError)?.message ?? String(describing: error)
    }
}

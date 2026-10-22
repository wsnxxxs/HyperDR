import Foundation

nonisolated struct LUTMetadataWrite: Sendable {
    var revision = 0
    var confirmed: LUTItem?
    var task: Task<Void, Never>?
}

/// A read begun during a pending write cannot be authoritative even if the
/// write finishes without another enqueue (and thus without a new revision).
nonisolated struct LUTLibraryReadVersion: Sendable {
    var revision = 0
    var wasWriting = false
}

extension EditorModel {
    /// The library publishes desired spaces immediately, and the look in use
    /// on that LUT takes them (`RecipeEditor.adoptLookSpaces`).
    func setLibraryLUTSpaces(_ id: String, input: LUTColorSpace, output: LUTColorSpace) {
        guard !isEditingLocked else { return }
        enqueueLUTSpaces(id, input: input, output: output)
        if let reference = lutReferences[id] {
            editor.adoptLookSpaces(reference.contentHash, input: input.rawValue, output: output.rawValue)
        }
    }

    func enqueueLUTSpaces(_ id: String, input: LUTColorSpace, output: LUTColorSpace) {
        var write = lutMetadataWrites[id] ?? LUTMetadataWrite()
        if write.task == nil { write.confirmed = lut.library.first { $0.id == id } }
        write.revision &+= 1
        let revision = write.revision, previous = write.task
        let sourceID = editor.source?.id
        if let index = lut.library.firstIndex(where: { $0.id == id }) {
            lut.library[index].input = input
            lut.library[index].output = output
        }
        write.task = Task { [weak self, services] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let item = try await services.updateLUT(id, input: input, output: output)
                guard let self, !Task.isCancelled else { return }
                // Even an obsolete success advances the persisted rollback base.
                lutMetadataWrites[id]?.confirmed = item
                guard lutMetadataWrites[id]?.revision == revision else { return }
                lutMetadataWrites[id]?.task = nil
                if let index = lut.library.firstIndex(where: { $0.id == id }) {
                    lut.library[index] = item
                } else {
                    // A newer membership read may have removed this id. Re-read
                    // disk rather than dropping a successful write or reviving
                    // a deliberately deleted item from its obsolete response.
                    await refreshLUTLibrary()
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                lut.failures = [UserFacingError.service(error)]
                guard lutMetadataWrites[id]?.revision == revision else { return }
                let confirmed = lutMetadataWrites[id]?.confirmed
                if let confirmed, let index = lut.library.firstIndex(where: { $0.id == id }) {
                    lut.library[index] = confirmed
                    if editor.source?.id == sourceID, let reference = lutReferences[id] {
                        editor.reconcileLookSpaces(reference.contentHash,
                                                  attemptedInput: input.rawValue, attemptedOutput: output.rawValue,
                                                  input: confirmed.input.rawValue, output: confirmed.output.rawValue)
                    }
                }
                lutMetadataWrites[id]?.task = nil
            }
        }
        lutMetadataWrites[id] = write
        // Retained as an aggregate drain for tests and existing callers. Each
        // LUT serializes with itself; unrelated LUTs do not block one another.
        let pending = lutMetadataWrites.values.compactMap(\.task)
        lutMetadataTask = Task { for task in pending { await task.value } }
    }

    func lutLibraryReadVersions() -> [String: LUTLibraryReadVersion] {
        lutMetadataWrites.mapValues { LUTLibraryReadVersion(revision: $0.revision, wasWriting: $0.task != nil) }
    }

    /// A membership mutation fences every earlier read, even if its own
    /// post-mutation refresh has not returned yet.
    func invalidateLUTLibraryReads() {
        lutLibraryReadSequence &+= 1
        lutLibraryAcceptedSequence = lutLibraryReadSequence
    }

    /// Capture field and membership ordering before suspending. Once a newer
    /// list commits, an older whole list cannot add or remove any members.
    func refreshLUTLibrary() async {
        lutLibraryReadSequence &+= 1
        let sequence = lutLibraryReadSequence
        let versions = lutLibraryReadVersions()
        let entries = await services.lutEntries()
        guard !Task.isCancelled, sequence > lutLibraryAcceptedSequence else { return }
        lutLibraryAcceptedSequence = sequence
        mergeLUTLibrary(entries, reading: versions)
        installLibraryLUTs()
        syncLUTState()
    }

    /// Pending-at-read, pending-now, and mutations since the read all supersede
    /// its metadata. Later reads begun after completion may replace confirmed
    /// values, so legitimate imports and refreshes remain authoritative.
    func mergeLUTLibrary(_ entries: [LUTItem], reading versions: [String: LUTLibraryReadVersion]) {
        lut.library = entries.map { item in
            let before = versions[item.id] ?? LUTLibraryReadVersion()
            let write = lutMetadataWrites[item.id]
            guard before.wasWriting || write?.task != nil || before.revision != (write?.revision ?? 0),
                  let current = lut.library.first(where: { $0.id == item.id }) else { return item }
            var result = item
            result.input = current.input; result.output = current.output
            return result
        }
    }
}

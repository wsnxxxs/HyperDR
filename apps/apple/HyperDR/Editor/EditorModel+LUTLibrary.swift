import Foundation

nonisolated struct LUTMetadataWrite: Sendable {
    var revision = 0
    var confirmed: LUTItem?
    var task: Task<Void, Never>?
}

extension EditorModel {
    /// The library publishes desired spaces immediately. The selected look
    /// continues to use the photo editing path, including its undo boundary.
    func setLibraryLUTSpaces(_ id: String, input: LUTColorSpace, output: LUTColorSpace) {
        guard !isEditingLocked else { return }
        if id == edit.lutID { setLUTSpaces(input: input, output: output); return }
        enqueueLUTSpaces(id, input: input, output: output, selectedPhoto: nil)
    }

    func enqueueLUTSpaces(_ id: String, input: LUTColorSpace, output: LUTColorSpace, selectedPhoto: EditorPhoto?) {
        var write = lutMetadataWrites[id] ?? LUTMetadataWrite()
        if write.task == nil { write.confirmed = lut.library.first { $0.id == id } }
        write.revision &+= 1
        let revision = write.revision, previous = write.task, openGeneration = generation
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
                if let index = lut.library.firstIndex(where: { $0.id == id }) { lut.library[index] = item }
                lutMetadataWrites[id]?.task = nil
            } catch {
                guard let self, !Task.isCancelled else { return }
                lut.failures = [UserFacingError.service(error)]
                guard lutMetadataWrites[id]?.revision == revision else { return }
                let confirmed = lutMetadataWrites[id]?.confirmed
                if let confirmed, let index = lut.library.firstIndex(where: { $0.id == id }) {
                    lut.library[index] = confirmed
                }
                lutMetadataWrites[id]?.task = nil
                // A failed library write may roll back this photo's matching
                // optimistic spaces, but never a new photo, selection or undo.
                if let selectedPhoto, generation == openGeneration, photo == selectedPhoto, edit.lutID == id,
                   edit.choices["lutInput"] == input.rawValue,
                   edit.choices["lutOutput"] == output.rawValue, let confirmed {
                    edit.choices["lutInput"] = confirmed.input.rawValue
                    edit.choices["lutOutput"] = confirmed.output.rawValue
                    editChanged()
                }
            }
        }
        lutMetadataWrites[id] = write
        // Retained as an aggregate drain for tests and existing callers. Each
        // LUT serializes with itself; unrelated LUTs do not block one another.
        let pending = lutMetadataWrites.values.compactMap(\.task)
        lutMetadataTask = Task { for task in pending { await task.value } }
    }

    /// Refreshing the library must not replace choices whose writes are pending.
    func mergeLUTLibrary(_ entries: [LUTItem]) {
        lut.library = entries.map { item in
            guard lutMetadataWrites[item.id]?.task != nil,
                  let desired = lut.library.first(where: { $0.id == item.id }) else { return item }
            var result = item
            result.input = desired.input; result.output = desired.output
            return result
        }
    }
}

import Foundation
import HyperDRRecipe
import HyperDRRender

/// A LUT the host's library offers: its library id and its name.
nonisolated struct LibraryLUT: Sendable, Hashable {
    let id: String
    let name: String
}

/// Library LUTs into the editor, for the Mac and iOS hosts: read the `.cube`
/// bytes, parse it, hand it to the editor (which keeps it for exports, see
/// `exportCapture`) and name it for the controls.
extension RecipeEditor {
    /// Installs `items` in order. `cube` reads a LUT's bytes by library id;
    /// `installed` hears each LUT's reference as soon as it is in. Returns
    /// the names of the LUTs that could not be read or parsed. Stops early
    /// when the task is cancelled.
    func installLibraryLUTs(_ items: [LibraryLUT], cube: (String) async throws -> Data,
                            installed: (String, LUTReference) -> Void) async -> [String] {
        var failures: [String] = []
        for item in items {
            guard !Task.isCancelled else { break }
            do {
                let lut = try ColorLUT(data: try await cube(item.id))
                await installLUT(lut)
                installed(item.id, LUTReference(contentHash: lut.contentHash, name: item.name))
            } catch {
                guard !Task.isCancelled else { break }
                failures.append(item.name)
            }
        }
        return failures
    }

    /// The recipe's look when the editor does not have its LUT: an export of
    /// this recipe cannot start until it is installed or the look is removed.
    var missingLook: LUTReference? {
        guard let look = recipe.activeLook, !hasLUT(look.contentHash) else { return nil }
        return look
    }
}

/// A LUT's input and output spaces are the LUT's own, as its maker specifies
/// them: the library records them, and the look on that LUT takes them. Set
/// in the library, they change the look in use at once; chosen on the look,
/// they are recorded in the library for the next time the LUT is chosen.
extension RecipeEditor {
    /// The library's spaces for a LUT changed: the look on it takes them, as
    /// one undo step. Nothing happens when the look is on another LUT.
    func adoptLookSpaces(_ contentHash: String, input: String, output: String) {
        guard recipe.look?.contentHash == contentHash else { return }
        let before = recipe
        apply(.parameter("look.input")) { recipe in
            if Adjustments.allowsLook(input: input, output: output, domain: recipe.inputDomain) {
                recipe.setLookSpaces(input: input, output: output)
            } else {
                recipe.look = nil
            }
        }
        if recipe.look == nil {
            incompatibleLookWrite = (source?.id, contentHash, before, recipe)
        } else {
            incompatibleLookWrite = nil
        }
    }
}

extension Recipe {
    /// Keep the library LUT's exact declared encodings, including when a stale
    /// restored recipe is incompatible. Render must reject it, never relabel it.
    nonisolated mutating func setLookSpaces(input: String, output: String) {
        for (id, space) in [("look.input", input), ("look.output", output)] {
            setValue(.string(space), for: id)
        }
    }

    /// The spaces a control write chose for the same look's LUT, each side
    /// only when it changed, for the library to record.
    nonisolated static func chosenLookSpaces(from old: Recipe, to new: Recipe)
        -> (contentHash: String, input: String?, output: String?)? {
        guard let hash = new.look?.contentHash, old.look?.contentHash == hash else { return nil }
        func chosen(_ id: String) -> String? {
            guard let value = new.conditionValue(id)?.stringValue, old.conditionValue(id)?.stringValue != value else { return nil }
            return value
        }
        let input = chosen("look.input"), output = chosen("look.output")
        return input == nil && output == nil ? nil : (hash, input, output)
    }
}

extension RecipeEditor {
    /// Chooses a library LUT as the look, with its spaces, or none: one undo
    /// step, as the look picker makes it.
    func chooseLook(_ reference: LUTReference?, input: String, output: String) {
        guard reference == nil || Adjustments.allowsLook(input: input, output: output, domain: recipe.inputDomain) else { return }
        apply(.parameter(Recipe.lookID)) { recipe in
            recipe.look = reference
            if reference == nil { recipe.setValue(nil, for: Recipe.filmID) }
            if reference != nil { recipe.setLookSpaces(input: input, output: output) }
        }
    }

    /// A LUT left the library: a look on it goes too, as one undo step, so
    /// the edit never names a LUT that can no longer be exported.
    func dropLook(_ contentHash: String) {
        guard recipe.look?.contentHash == contentHash else { return }
        apply(.parameter(Recipe.lookID)) { $0.look = nil }
    }
}

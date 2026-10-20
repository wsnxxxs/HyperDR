import Foundation
import HyperDRRecipe
import HyperDRRender

/// A LUT the host's library offers: its library id and its name.
nonisolated struct LibraryLUT: Sendable, Hashable {
    let id: String
    let name: String
}

/// Library LUTs into the editor, for the Mac and iOS hosts: read the `.cube`
/// text, parse it, hand it to the editor (which keeps it for exports, see
/// `exportCapture`) and name it for the controls.
extension RecipeEditor {
    /// Installs `items` in order. `cube` reads a LUT's text by library id;
    /// `installed` hears each LUT's reference as soon as it is in. Returns
    /// the names of the LUTs that could not be read or parsed. Stops early
    /// when the task is cancelled.
    func installLibraryLUTs(_ items: [LibraryLUT], cube: (String) async throws -> String,
                            installed: (String, LUTReference) -> Void) async -> [String] {
        var failures: [String] = []
        for item in items {
            guard !Task.isCancelled else { break }
            do {
                let lut = try ColorLUT(cube: try await cube(item.id))
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

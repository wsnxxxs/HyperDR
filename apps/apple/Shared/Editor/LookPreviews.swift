import CoreGraphics
import Foundation
import HyperDRRecipe
import Observation

/// What each library LUT does to the open photo, for the look pickers: small
/// SDR renders of the recipe with that LUT as its look, and one with none.
///
/// - A preview is what choosing the LUT gives: the recipe's look switch and
///   strength are kept, its spaces the library's (a space the photo cannot take, a Log
///   input outside RAW, at its default), everything else as edited.
/// - Hosts call `update` whenever the recipe or the library changes, and
///   `shown` as pickers appear and disappear (`lookPickerShown`): renders
///   run only while one is shown. Nothing renders during a drag; they start a
///   moment after the last change, one at a time, each from the source the
///   preview has open. A LUT whose look needs another development (a Log
///   look on a RAW developed for display) gets no preview, and the picker
///   shows its colour mark instead.
/// - Older previews stay up until their replacements land, so a change
///   never blanks the row.
@MainActor @Observable final class LookPreviews {
    /// A library LUT and the spaces the library records for it (`look.input`
    /// and `look.output` option ids).
    struct Look: Equatable, Sendable {
        let reference: LUTReference
        let input: String
        let output: String
    }

    /// The key of the preview without a LUT in `images`.
    static let none = ""
    /// The long edge of a preview, in pixels: a 64-point tile at 3×.
    static let side = 192

    /// Previews by content hash, and `none`.
    private(set) var images: [String: CGImage] = [:]

    @ObservationIgnored private var wanted: LookPreviewInputs?
    @ObservationIgnored private var imageSource: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Pickers on screen.
    @ObservationIgnored private var pickers = 0
    /// The latest `update`, for when a picker appears.
    @ObservationIgnored private weak var editor: RecipeEditor?
    @ObservationIgnored private var looks: [Look] = []

    func shown(_ isShown: Bool) {
        pickers = max(0, pickers + (isShown ? 1 : -1))
        if pickers == 0 {
            stop()
        } else if let editor {
            update(editor, looks: looks)
        }
    }

    func update(_ editor: RecipeEditor, looks: [Look]) {
        self.editor = editor
        self.looks = looks
        guard let source = editor.source else {
            stop()
            images = [:]
            return
        }
        if imageSource != source.id {
            images = [:]
            imageSource = source.id
        }
        guard pickers > 0, !editor.isDragging else {
            stop()
            return
        }
        let key = LookPreviewInputs(editor: editor, looks: looks)
        guard key != wanted else { return }
        wanted = key
        task?.cancel()
        let base = Self.base(editor.recipe)
        let jobs = [(Self.none, base)] + looks.map { ($0.reference.contentHash, Self.recipe(base, with: $0)) }
        task = Task { [weak self, weak editor] in
            try? await Task.sleep(for: .milliseconds(250))
            for (id, recipe) in jobs {
                guard !Task.isCancelled, let editor, !editor.isDragging else { return }
                let image = try? await editor.lookPreview(recipe, side: Self.side)
                guard !Task.isCancelled, let self else { return }
                images[id] = image
            }
            guard let self else { return }
            let kept = Set(jobs.map(\.0))
            images = images.filter { kept.contains($0.key) }
        }
    }

    /// Stops rendering; the next `update` starts again.
    func stop() {
        task?.cancel()
        task = nil
        wanted = nil
    }

    /// The recipe without its LUT and spaces. Choosing a LUT preserves the
    /// switch and strength, including a disabled look or zero strength.
    static func base(_ recipe: Recipe) -> Recipe {
        var base = recipe
        base.look = nil
        for id in ["look.input", "look.output"] { base.setValue(nil, for: id) }
        return base
    }

    static func recipe(_ base: Recipe, with look: Look) -> Recipe {
        var recipe = base
        recipe.look = look.reference
        recipe.setLookSpaces(input: look.input, output: look.output)
        return recipe
    }
}

/// What the previews depend on, for a host's `onChange`: the photo, the
/// edit, whether a drag is open, and the library's LUTs.
struct LookPreviewInputs: Equatable {
    let source: UUID?
    let recipe: Recipe
    let isDragging: Bool
    // A completed canvas render signals that its development is available.
    // AI may finish without changing the recipe or request.
    let rendered: EditorRenderRequest?
    let modelGainPending: Bool
    let aiStatus: RecipeEditor.AIStatus
    let looks: [LookPreviews.Look]

    init(editor: RecipeEditor, looks: [LookPreviews.Look]) {
        source = editor.source?.id
        recipe = editor.recipe
        isDragging = editor.isDragging
        rendered = editor.frame?.request
        modelGainPending = editor.isModelGainPending
        aiStatus = editor.aiStatus
        self.looks = looks
    }
}

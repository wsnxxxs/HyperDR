import CoreGraphics
import Foundation
import HyperDRRecipe
import HyperDRRender
import Observation

/// What each look does to the open photo, for the look pickers: small SDR
/// renders of the recipe with each built-in film stock and each library LUT
/// as its look, and one with none.
///
/// - A preview is what choosing the look gives: the recipe's look switch and
///   strengths are kept, a LUT's spaces the library's, everything else as
///   edited. Incompatible LUTs are omitted.
/// - Hosts call `update` whenever the recipe or the library changes, and
///   `shown` as pickers appear and disappear (`lookPickerShown`): renders
///   run only while one is shown. Nothing renders during a drag; they start a
///   moment after the last change, one at a time. RAW's display and scene
///   renditions are prepared on demand and reused without selecting a look.
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

    /// The key of the preview without a look in `images`.
    static let none = ""
    /// The key of a built-in film stock's preview in `images`; a LUT's is its content hash.
    static func filmKey(_ stock: String) -> String { "film:" + stock }
    /// The long edge of a preview, in pixels: a 64-point tile at 3×.
    static let side = 192

    /// Previews by content hash, `filmKey`, and `none`.
    private(set) var images: [String: CGImage] = [:]

    @ObservationIgnored private var wanted: LookPreviewInputs?
    @ObservationIgnored private var completed: LookPreviewInputs?
    /// Successful tiles of an interrupted batch survive closing the picker.
    @ObservationIgnored private var renderedInputs: LookPreviewInputs?
    @ObservationIgnored private var renderedIDs: Set<String> = []
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
            completed = nil
            return
        }
        if imageSource != source.id {
            images = [:]
            completed = nil
            imageSource = source.id
        }
        guard pickers > 0, !editor.isDragging, editor.frameIsCurrent,
              !editor.isRefiningPreview, !editor.isYieldingToExport else {
            stop()
            return
        }
        let key = LookPreviewInputs(editor: editor, looks: looks)
        // Selection and physical effects do not change the colour thumbnails.
        // A completed set remains valid through those edits and picker reopens.
        if key == completed { wanted = key; return }
        guard key != wanted else { return }
        wanted = key
        // This batch replaces images incrementally. Once it starts, an older
        // completed key cannot describe the possibly mixed set on screen.
        completed = nil
        task?.cancel()
        if renderedInputs != key {
            renderedInputs = key
            renderedIDs = []
        }
        let base = Self.base(editor.recipe)
        let films = Adjustments.filmStocks.dropFirst().map { (Self.filmKey($0), Self.recipe(base, film: $0)) }
        let imported = looks.filter {
            Adjustments.allowsLook(input: $0.input, output: $0.output, domain: base.inputDomain)
        }.map { ($0.reference.contentHash, Self.recipe(base, with: $0)) }
        let jobs = [(Self.none, base)] + imported + films
        let pendingJobs = jobs.filter { !renderedIDs.contains($0.0) }
        task = Task { [weak self, weak editor] in
            try? await Task.sleep(for: .milliseconds(250))
            var failed = false
            for (id, recipe) in pendingJobs {
                guard !Task.isCancelled, let editor, !editor.isDragging,
                      editor.frameIsCurrent, !editor.isYieldingToExport else { return }
                let image = try? await editor.lookPreview(recipe, side: Self.side)
                guard !Task.isCancelled, let self else { return }
                if let image {
                    images[id] = image
                    renderedIDs.insert(id)
                }
                else { failed = true }
            }
            guard let self else { return }
            let kept = Set(jobs.map(\.0))
            images = images.filter { kept.contains($0.key) }
            // A transient failure must not permanently cache a blank tile.
            completed = failed ? nil : key
            wanted = failed ? nil : key
            task = nil
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
    /// The tiles compare colour, which is all a look changes, so they leave
    /// out the effects (grain and halation, which a tile's size would only
    /// turn into noise).
    static func base(_ recipe: Recipe) -> Recipe {
        var base = recipe
        base.look = nil
        base.setValue(nil, for: Recipe.filmID)
        for id in ["look.input", "look.output"] { base.setValue(nil, for: id) }
        for id in Adjustments.effectIDs { base.setValue(nil, for: id) }
        return base
    }

    static func recipe(_ base: Recipe, film stock: String) -> Recipe {
        var recipe = base
        recipe.setValue(.string(stock), for: Recipe.filmID)
        return recipe
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
    let isCurrent: Bool
    let isRefining: Bool
    let isYielding: Bool
    // A completed canvas render signals that its development is available.
    // AI may finish without changing the recipe or request.
    let rendered: EditorRenderRequest?
    let modelGainPending: Bool
    let aiStatus: RecipeEditor.AIStatus
    let looks: [LookPreviews.Look]

    init(editor: RecipeEditor, looks: [LookPreviews.Look]) {
        source = editor.source?.id
        recipe = LookPreviews.base(editor.recipe)
        isDragging = editor.isDragging
        isCurrent = editor.frameIsCurrent
        isRefining = editor.isRefiningPreview
        isYielding = editor.isYieldingToExport
        var frame = editor.frame?.request
        // Each thumbnail prepares its own rendition. Selecting a Log look
        // no longer changes which other looks the completed set can preview.
        if let request = frame { frame?.recipe = LookPreviews.base(request.recipe) }
        frame?.isInteractive = false
        rendered = frame
        modelGainPending = editor.isModelGainPending
        aiStatus = editor.aiStatus
        self.looks = looks
    }
}

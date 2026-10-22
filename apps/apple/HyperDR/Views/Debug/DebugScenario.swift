#if DEBUG
import Foundation

/// Debug builds only: `-HDRPreviewScenario editingHDRDisplay` (any
/// `PreviewScenario` case name) launches the main window on that fixture
/// instead of the scene's model, so every state can be checked and captured
/// in a real window with its real toolbar.
enum DebugScenario {
    static let model: EditorModel? = {
        guard let name = UserDefaults.standard.string(forKey: "HDRPreviewScenario"),
              let scenario = PreviewScenario.allCases.first(where: { "\($0)" == name })
        else { return nil }
        return EditorModel.preview(scenario)
    }()
}
#endif

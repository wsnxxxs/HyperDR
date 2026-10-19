extension EditorModel {
    /// Whether the menu's Open… and the toolbar's open button are enabled:
    /// the engine is up and no open, restore, first frame or AI computation
    /// is in the way (`canOpenDocument`). Only these two commands follow it;
    /// Finder and drag-and-drop may still replace a photo that is opening
    /// (Q14).
    var allowsOpenCommand: Bool { engine.failure == nil && canOpenDocument }
}

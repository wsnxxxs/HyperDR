import Testing
import HyperDRRender

extension Trait where Self == ConditionTrait {
    /// The AI model is not in the repository (Resources/Models/README.md): tests
    /// that load it run only where a private copy was put in place.
    static var needsModel: Self {
        .enabled(if: ModelGain.isIncluded, "the AI model is not included in this checkout")
    }
}

import SwiftUI

extension ViewMode {
    /// The segment title, from the web panel's `editor.*` keys.
    var label: LocalizedStringKey {
        switch self {
        case .original: "editor.original"
        case .edited: "editor.effect"
        case .compare: "editor.compare"
        }
    }
}

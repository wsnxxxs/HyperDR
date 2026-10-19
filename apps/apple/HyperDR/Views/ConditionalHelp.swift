import SwiftUI

extension View {
    /// A tooltip only while there is something to say. `.help` with an empty
    /// text still claims the view's area, and so hides the hint of an
    /// enclosing view over it (the lock note over a control that has none).
    @ViewBuilder func help(when text: LocalizedStringKey?) -> some View {
        if let text { help(Text(text)) } else { self }
    }
}

import SwiftUI

struct EditorCommands: Commands {
    // F2 supplies macOS menu shortcuts (Cmd0, Cmd1, Cmd+/Cmd-). Focus-scoped
    // M1 focus keys F/+/− are handled by Views using CanvasModel actions.
    // C and hold-Space belong to M2; PreviewCanvas never handles keyboard input.
    var body: some Commands { EmptyCommands() }
}

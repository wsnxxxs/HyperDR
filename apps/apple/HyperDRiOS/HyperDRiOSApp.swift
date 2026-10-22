import SwiftUI

/// HyperDR on iPhone and iPad: pick a photo, edit it in HDR, frame it, export it.
@main
struct HyperDRiOSApp: App {
    init() {
        // No scene is open yet: copies from an earlier run are nobody's.
        ImportedPhoto.discardAll()
    }

    var body: some Scene {
        WindowGroup {
            StudioRoot()
                .preferredColorScheme(.dark)
        }
    }
}

/// The scene: the library to pick from, and the editor over it while a photo
/// is open. One session per scene, so two iPad windows edit two photos.
struct StudioRoot: View {
    @State private var session = EditingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        HomeScreen(session: session)
            .fullScreenCover(isPresented: $session.isEditing, onDismiss: session.editorDismissed) {
                if let editor = session.editor { EditorScreen(session: session, editor: editor) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { session.exports.enteredBackground() }
            }
            #if DEBUG
            .task { DebugLaunch.open(into: session) }
            #endif
    }
}

#if DEBUG
/// `-HyperDROpen <path>` opens a file at launch, for trying the editor in the
/// Simulator without the picker; `-HyperDRLandscape` turns the window to
/// landscape at launch (iPadOS refuses it later, in a windowed scene).
/// Developer-only.
enum DebugLaunch {
    static func open(into session: EditingSession) {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-HyperDRLandscape"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        guard let index = arguments.firstIndex(of: "-HyperDROpen"), index + 1 < arguments.count else { return }
        session.open(.file(URL(filePath: arguments[index + 1])))
    }
}
#endif

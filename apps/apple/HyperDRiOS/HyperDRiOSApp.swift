import HyperDRRender
import SwiftUI

/// HyperDR on iPhone and iPad: pick a photo, edit it in HDR, frame it, export it.
@main
struct HyperDRiOSApp: App {
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-HyperDRForceRAWCompatibility") {
            RenderEngine.forcesRAWCompatibility = true
        }
        #endif
        DiagnosticLog.shared.start()
        MetricsCollector.shared.start()
        // No scene is open yet: copies from an earlier run are nobody's.
        ImportedPhoto.discardAll()
        // Captions set in an imported font need it before the first frame draws.
        FrameFontLibrary.shared.registerAll()
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
///
/// An iPad window of regular width gets the Studio (`PadHome`, `PadEditor`;
/// docs/design/ipad-studio.md); the iPhone, and an iPad window as narrow as
/// one, the iPhone's screens. The choice is made inside the cover too, so a
/// window resized while a photo is open swaps the editor and keeps the edit.
struct StudioRoot: View {
    @State private var session = EditingSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if StudioRoot.usesStudio(sizeClass) { PadHome(session: session) } else { HomeScreen(session: session) }
        }
        .fullScreenCover(isPresented: $session.isEditing, onDismiss: session.editorDismissed) {
            if let editor = session.editor { EditorRoot(session: session, editor: editor) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                DiagnosticLog.notice("App", "Entered background; available to the app \(DeviceFacts.availableMemory)")
                session.exports.enteredBackground()
            } else if phase == .active {
                DiagnosticLog.notice("App", "Active")
            }
        }
        #if DEBUG
        .task { DebugLaunch.open(into: session) }
        #endif
    }

    /// The iPad Studio is for iPad windows of regular width.
    static func usesStudio(_ sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }
}

/// The editor for the window's width: the Studio or the iPhone's.
private struct EditorRoot: View {
    let session: EditingSession
    let editor: RecipeEditor
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if StudioRoot.usesStudio(sizeClass) {
                PadEditor(session: session, editor: editor)
            } else {
                EditorScreen(session: session, editor: editor)
            }
        }
        // A RAW nothing here can develop, opened over a photo: too long for the notice.
        .alert(Text(session.editorFailure ?? ""), isPresented: Binding(
            get: { session.editorFailure != nil }, set: { if !$0 { session.editorFailure = nil } })) {
            Button("ios.common.ok", role: .cancel) {}
        }
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

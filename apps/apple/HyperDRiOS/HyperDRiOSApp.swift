import SwiftUI

/// HyperDR on iPhone and iPad: pick a photo, edit it in HDR.
@main
struct HyperDRiOSApp: App {
    init() {
        // No scene is open yet: copies from an earlier run are nobody's.
        ImportedPhoto.discardAll()
    }

    var body: some Scene {
        WindowGroup {
            PhotoCanvasScreen()
                .preferredColorScheme(.dark)
        }
    }
}

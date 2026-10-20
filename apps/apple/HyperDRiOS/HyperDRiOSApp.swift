import SwiftUI

/// HyperDR on iPhone and iPad. P7-0 is a shell: pick a photo, see it in HDR.
@main
struct HyperDRiOSApp: App {
    var body: some Scene {
        WindowGroup {
            PhotoCanvasScreen()
                .preferredColorScheme(.dark)
        }
    }
}

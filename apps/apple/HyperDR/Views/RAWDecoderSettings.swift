import HyperDRRender
import SwiftUI

/// Kept separate from the settings for the photo already on the canvas.
/// RAW 9 is listed only where this system has it; LibRaw is always offered.
struct RAWDecoderSettings: View {
    @Binding var selection: RAWDecoderPreference
    @Binding var matchesCameraPreview: Bool
    var offersRAW9 = RenderEngine.systemSupportsRAW9

    var body: some View {
        Section {
            Picker("settings.rawDeveloper", selection: $selection) {
                Text(offersRAW9 ? "settings.rawDeveloper.automatic" : "settings.rawDeveloper.automaticApple")
                    .tag(RAWDecoderPreference.automatic)
                Text("settings.rawDeveloper.eight").tag(RAWDecoderPreference.raw8)
                if offersRAW9 {
                    Text("settings.rawDeveloper.nine").tag(RAWDecoderPreference.raw9)
                }
                Divider()
                Text("settings.rawDeveloper.libraw").tag(RAWDecoderPreference.libRAW)
            }
            Toggle("settings.rawBrightness", isOn: $matchesCameraPreview)
        } header: {
            Text("settings.rawDevelopment")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(offersRAW9 ? "settings.rawDeveloper.note" : "settings.rawDeveloper.noteWithoutNine")
                Text("settings.rawBrightness.note")
                if selection == .libRAW {
                    Text("settings.rawDeveloper.libraw.note")
                }
            }
        }
    }
}

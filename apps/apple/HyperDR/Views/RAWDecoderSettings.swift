import SwiftUI

/// Kept separate from the settings for the photo already on the canvas.
struct RAWDecoderSettings: View {
    @Binding var selection: RAWDecoderPreference

    var body: some View {
        Section {
            Picker("settings.rawDeveloper", selection: $selection) {
                Text("settings.rawDeveloper.automatic").tag(RAWDecoderPreference.automatic)
                Text("settings.rawDeveloper.eight").tag(RAWDecoderPreference.raw8)
                Text("settings.rawDeveloper.nine").tag(RAWDecoderPreference.raw9)
            }
        } header: {
            Text("settings.rawDevelopment")
        } footer: {
            Text("settings.rawDeveloper.note")
        }
    }
}

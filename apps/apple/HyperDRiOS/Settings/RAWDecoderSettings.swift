import SwiftUI

struct RAWDecoderSettings: View {
    @Binding var selection: RAWDecoderPreference
    @Binding var matchesCameraPreview: Bool

    var body: some View {
        Section {
            Picker("ios.settings.rawDeveloper", selection: $selection) {
                Text("ios.settings.rawDeveloper.automatic").tag(RAWDecoderPreference.automatic)
                Text("ios.settings.rawDeveloper.eight").tag(RAWDecoderPreference.raw8)
                Text("ios.settings.rawDeveloper.nine").tag(RAWDecoderPreference.raw9)
            }
            Toggle("ios.settings.rawBrightness", isOn: $matchesCameraPreview)
        } header: {
            Text("ios.settings.rawDevelopment")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("ios.settings.rawDeveloper.note")
                Text("ios.settings.rawBrightness.note")
            }
        }
    }
}

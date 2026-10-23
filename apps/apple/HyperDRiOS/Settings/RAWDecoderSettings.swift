import SwiftUI

struct RAWDecoderSettings: View {
    @Binding var selection: RAWDecoderPreference

    var body: some View {
        Section {
            Picker("ios.settings.rawDeveloper", selection: $selection) {
                Text("ios.settings.rawDeveloper.automatic").tag(RAWDecoderPreference.automatic)
                Text("ios.settings.rawDeveloper.eight").tag(RAWDecoderPreference.raw8)
                Text("ios.settings.rawDeveloper.nine").tag(RAWDecoderPreference.raw9)
            }
        } header: {
            Text("ios.settings.rawDevelopment")
        } footer: {
            Text("ios.settings.rawDeveloper.note")
        }
    }
}

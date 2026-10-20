#if DEBUG
import HyperDRDesign
import HyperDRRecipe
import SwiftUI

/// The generated adjustment controls on a fake recipe (P7-2a), from the More
/// menu or the empty state in debug builds. The canvas is a stand-in that
/// prints the recipe; nothing is rendered. Developer text here is not localized.
struct AdjustmentsDebugScreen: View {
    @State private var recipe = Recipe(inputDomain: .rawEDR)
    @State private var confirmingReset = false
    @Environment(\.dismiss) private var dismiss
    private let panel = AdjustmentPanel(context: .gallery)

    var body: some View {
        NavigationStack {
            AdjustmentWorkspace(recipe: $recipe, panel: panel) {
                ScrollView {
                    Text(verbatim: (try? recipe.jsonString(pretty: true)) ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LinearGradient(colors: [.black, Color(white: 0.18)], startPoint: .top, endPoint: .bottom))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Text(verbatim: "Close") }
                }
                ToolbarItem(placement: .principal) {
                    Picker(selection: Binding(get: { recipe.inputDomain }, set: { recipe.setInputDomain($0) })) {
                        ForEach(InputDomain.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    } label: {
                        Text(verbatim: "Input domain")
                    }
                    .pickerStyle(.menu)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) { confirmingReset = true } label: { AdjustmentText.command(.resetAll) }
                    } label: {
                        Label("ios.toolbar.more", systemImage: "ellipsis")
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(Text("ios.adjust.resetAll.confirm"), isPresented: $confirmingReset, titleVisibility: .visible) {
                Button(role: .destructive) { panel.resetAll(in: &recipe) } label: { AdjustmentText.command(.resetAll) }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif

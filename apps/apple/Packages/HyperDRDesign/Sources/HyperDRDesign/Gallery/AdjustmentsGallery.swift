import HyperDRRecipe
import SwiftUI

/// The generated adjustment controls on a fake recipe (P7-2a): the inspector
/// with the pointer and the touch style side by side, a picker for the input
/// domain and the recipe's JSON, for the Mac's Developer menu and previews.
/// Nothing here is wired to rendering.
public struct AdjustmentsGallery: View {
    @State private var recipe: Recipe
    private let panel: AdjustmentPanel

    public init(domain: InputDomain = .rawEDR) {
        _recipe = State(initialValue: Recipe(inputDomain: domain))
        panel = AdjustmentPanel(context: .gallery)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 24) {
            column(.pointer, width: 300)
            column(.touch, width: 320)
            VStack(alignment: .leading, spacing: Space.s3) {
                Picker(selection: Binding(get: { recipe.inputDomain }, set: { recipe.setInputDomain($0) })) {
                    ForEach(InputDomain.allCases, id: \.self) { domain in
                        Text(verbatim: domain.rawValue).tag(domain)
                    }
                } label: {
                    Text(verbatim: "Input domain")
                }
                .pickerStyle(.segmented)
                ScrollView {
                    Text(verbatim: (try? recipe.jsonString(pretty: true)) ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 320)
        }
        .padding(24)
        .background(Color.hdr.surfacePage)
    }

    private func column(_ style: AdjustmentControlStyle, width: CGFloat) -> some View {
        ScrollView {
            AdjustmentInspector(recipe: $recipe, panel: panel, style: style)
                .padding(.vertical, Space.s3)
        }
        .frame(width: width)
        .background(Color.hdr.surfacePanel)
    }
}

extension AdjustmentContext {
    /// A made-up source for galleries and debug screens: every capability
    /// held, a plausible value for each `fromSource` and `auto` default, two
    /// LUTs and two models. Derived from the declarations, not listed.
    public static var gallery: AdjustmentContext {
        var source: [String: Double] = [:]
        var automatic: [String: Double] = [:]
        var capabilities = Set<String>()
        for declaration in Adjustments.all {
            if let capability = declaration.capability { capabilities.insert(capability) }
            guard let range = declaration.range else { continue }
            let step = declaration.step ?? 1
            let middle = range.lowerBound + ((range.upperBound - range.lowerBound) * 0.3 / step).rounded() * step
            switch declaration.default {
            case .fromSource:
                source[declaration.id] = declaration.format == .kelvin ? 5600 : declaration.origin == .zero ? 0 : middle
            case .auto:
                automatic[declaration.id] = middle
            default:
                break
            }
        }
        return AdjustmentContext(
            sourceValues: source, automaticValues: automatic, capabilities: capabilities,
            luts: [LUTReference(contentHash: "sha256:0001", name: "Kodak 2383"),
                   LUTReference(contentHash: "sha256:0002", name: "Fuji 3513")],
            models: [AdjustmentModelChoice(id: "research-cnn-v1", name: "Research CNN v1"),
                     AdjustmentModelChoice(id: "research-cnn-v2", name: "Research CNN v2")])
    }
}

#Preview("Adjustments") {
    AdjustmentsGallery().frame(width: 1060, height: 900)
}

import SwiftUI
import HyperDREngine
import HyperDRDesign

struct AppContentView: View {
    @State private var schemaCount: Int?
    @State private var engineError: String?
    @State private var previewError: String?
    @State private var headroom = HeadroomSnapshot()
    @State private var original = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("HyperDR").font(.largeTitle.bold())
                Spacer()
                VStack(alignment: .trailing) {
                    Text(verbatim: "Engine \(Engine.version) · ABI \(Engine.abiVersion)")
                    if let schemaCount { Text(verbatim: "Settings: \(schemaCount)") }
                }.font(.system(.body, design: .monospaced))
            }
            if let engineError { Text(verbatim: engineError).foregroundStyle(.red) }
            Text(verbatim: "Metal EDR preview prototype").font(.title2)
            Text(verbatim: "Linear Display P3 · synthetic 0–8× HDR ramp").foregroundStyle(.secondary)
            EDRPreview(original: original, onHeadroom: { headroom = $0 }, onError: { previewError = $0 })
                .frame(minHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Text("0×")
                Spacer()
                Text("4×")
                Spacer()
                Text("8×")
            }.font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Toggle(isOn: $original) { Text(verbatim: "SDR only (clamped to 1×)") }
            HStack(spacing: 24) {
                Text(verbatim: headroom.screen ?? "")
                Text(verbatim: "Current headroom: \(String(format: "%.2f", headroom.current))×")
                Text(verbatim: "Potential headroom: \(String(format: "%.2f", headroom.potential))×")
            }.font(.system(.body, design: .monospaced))
            if let previewError { Text(verbatim: "Preview failed: \(previewError)").foregroundStyle(.red) }
        }
        .padding(32)
        .background(Color.hdr.surfacePage)
        .foregroundStyle(Color.hdr.ink)
        .frame(minWidth: 800, minHeight: 520)
        .task {
            do {
                let schema = try Engine.schema()
                schemaCount = schema.settings.count
                print("HyperDR engine=\(Engine.version) abi=\(Engine.abiVersion) settings=\(schema.settings.count)")
            } catch { engineError = "Cannot read the engine settings: \(error.localizedDescription)" }
        }
    }
}

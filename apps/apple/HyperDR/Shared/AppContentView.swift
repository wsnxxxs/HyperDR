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
                    Text("引擎 \(Engine.version) · ABI \(Engine.abiVersion)")
                    if let schemaCount { Text("设置项：\(schemaCount)") }
                }.font(.system(.body, design: .monospaced))
            }
            if let engineError { Text(engineError).foregroundStyle(.red) }
            Text("Metal EDR 预览原型").font(.title2)
            Text("线性 Display P3 · 0–8× HDR 合成渐变").foregroundStyle(.secondary)
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
            Toggle("仅显示 SDR（限制在 1×）", isOn: $original)
            HStack(spacing: 24) {
                Text(headroom.screen)
                Text("当前 headroom：\(headroom.current, specifier: "%.2f")×")
                Text("潜在 headroom：\(headroom.potential, specifier: "%.2f")×")
            }.font(.system(.body, design: .monospaced))
            if let previewError { Text("预览未能运行：\(previewError)").foregroundStyle(.red) }
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
            } catch { engineError = "无法读取引擎设置：\(error.localizedDescription)" }
        }
    }
}

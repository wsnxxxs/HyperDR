import SwiftUI
import PhotosUI
import Photos
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ContentView: View {
    @StateObject private var model = LabModel()

    var body: some View {
        LogScreen(model: model, log: model.log)
    }
}

private struct LogScreen: View {
    @ObservedObject var model: LabModel
    @ObservedObject var log: LabLog

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pickerSection
                    settingsSection
                    stepsSection
                    logLocationSection
                    resultsSection
                }
                .padding()
                .frame(maxWidth: 900, alignment: .leading)
            }
            .onChange(of: log.entries.count) {
                if let last = log.entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 640)
        #endif
        .onAppear { model.refreshAuthorization() }
    }

    // MARK: 区块

    private var pickerSection: some View {
        GroupBox("选照片") {
            VStack(alignment: .leading, spacing: 8) {
                PhotosPicker(selection: $model.pickerItem, matching: .images,
                             preferredItemEncoding: .current, photoLibrary: .shared()) {
                    Label("选照片…", systemImage: "photo.on.rectangle")
                }
                .disabled(model.busy)
                if let id = model.assetIdentifier {
                    Text("已选：\(id)").font(.caption.monospaced()).textSelection(.enabled)
                } else if model.pickerItem != nil {
                    Text("选择器没有给出图库标识，无法原地编辑").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("还没选").font(.caption).foregroundStyle(.secondary)
                }
                if let s = model.pickedSummary {
                    Text(s).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Text("图库权限：\(PhotosService.name(of: model.authorization))").font(.caption)
                    Button("请求/刷新") { model.requestAuthorization() }.disabled(model.busy)
                    #if os(iOS)
                    if model.authorization == .limited {
                        Button("管理受限照片…") { presentLimitedPicker() }
                    }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var settingsSection: some View {
        GroupBox("写回设置（第 2、5 步用）") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("输出格式", selection: $model.variant) {
                    ForEach(OutputVariant.allCases) { Text($0.title).tag($0) }
                }
                Stepper(String(format: "曝光 %+.1f EV", model.exposure), value: $model.exposure, in: -2...2, step: 0.1)
                Picker("adjustmentData 大小", selection: $model.paddingKB) {
                    Text("约 1 KB").tag(1)
                    Text("约 100 KB").tag(100)
                    Text("约 1 MB").tag(1024)
                    Text("约 10 MB").tag(10 * 1024)
                }
            }
            .disabled(model.busy)
        }
    }

    private var stepsSection: some View {
        GroupBox("测试步骤（按顺序点）") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(1...6, id: \.self) { index in
                    Button(LabModel.stepNames[index - 1]) { model.runStep(index) }
                        .disabled(model.busy)
                }
                Divider()
                Button("依次运行 1–4（会弹两次系统确认框）") { model.runAll() }.disabled(model.busy)
                HStack {
                    Button("清除临时文件") { model.clearTemporaryFiles() }.disabled(model.busy)
                    if let step = model.currentStep {
                        ProgressView().controlSize(.small)
                        Text("正在运行：\(step)").font(.caption)
                    }
                }
                if !model.createdIdentifiers.isEmpty {
                    Text("⚠️ 图库里还有 \(model.createdIdentifiers.count) 张本测试创建的新照片，请点“6 删除新照片”。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logLocationSection: some View {
        GroupBox("日志文件") {
            VStack(alignment: .leading, spacing: 8) {
                Text(log.fileURL.path).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    ShareLink(item: log.fileURL) { Label("分享/导出日志", systemImage: "square.and.arrow.up") }
                    #if os(macOS)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([log.fileURL]) }
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultsSection: some View {
        GroupBox("结果") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(log.entries) { entry in
                    EntryRow(entry: entry).id(entry.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    #if os(iOS)
    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
    #endif
}

private struct EntryRow: View {
    let entry: LogEntry
    @State private var expanded = false

    private var symbol: String {
        switch entry.level {
        case .info: "•"
        case .ok: "✅"
        case .warn: "⚠️"
        case .fail: "❌"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(symbol)
                Text(entry.step).font(.caption.bold()).foregroundStyle(.secondary)
                Text(entry.message).font(.callout).textSelection(.enabled)
            }
            if !entry.details.isEmpty {
                DisclosureGroup("详情", isExpanded: $expanded) {
                    Text(JSONValue.object(entry.details).prettyText)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .padding(.leading, 20)
            }
        }
    }
}

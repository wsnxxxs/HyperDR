import Foundation
import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers

@MainActor
final class LabModel: ObservableObject {
    let log: LabLog

    @Published var pickerItem: PhotosPickerItem? {
        didSet { pickerChanged() }
    }
    @Published var variant: OutputVariant = .heicISOGainmap
    @Published var exposure: Double = 0.3
    /// adjustmentData 里额外塞多少 KB 的填充，用来测大小上限。
    @Published var paddingKB: Int = 1
    @Published private(set) var busy = false
    @Published private(set) var currentStep: String?
    @Published private(set) var authorization: PHAuthorizationStatus = PhotosService.status()
    @Published private(set) var pickedSummary: String?
    @Published private(set) var assetIdentifier: String?
    @Published private(set) var createdIdentifiers: [String] = []

    private var pickedReport: ImageReport?
    private var pickedURL: URL?
    private var originalLibraryReport: ImageReport?
    private var editBaseReport: ImageReport?
    private var writtenReport: ImageReport?
    private var lastRecipe: Data?

    init() {
        let env: [String: JSONValue] = [
            "os": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "machine": .string(Self.sysctlString("hw.machine") ?? "?"),
            "model": .string(Self.sysctlString("hw.model") ?? "?"),
            "bundleIdentifier": .string(Bundle.main.bundleIdentifier ?? "?"),
        ]
        log = LabLog(directory: LabPaths.documents, environment: env)
        log.add("启动", .info, "HyperDR Photos Lab 已启动", env)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    // MARK: 选择

    private func pickerChanged() {
        pickedReport = nil
        pickedURL = nil
        originalLibraryReport = nil
        editBaseReport = nil
        writtenReport = nil
        lastRecipe = nil
        assetIdentifier = pickerItem?.itemIdentifier
        pickedSummary = nil
        guard let item = pickerItem else { return }
        log.add("选图", .info, "已选择照片", [
            "itemIdentifier": .string(item.itemIdentifier ?? "nil（没有 PHAsset 标识，无法原地编辑）"),
            "supportedContentTypes": .array(item.supportedContentTypes.map { .string($0.identifier) }),
        ])
    }

    // MARK: 权限

    func refreshAuthorization() {
        authorization = PhotosService.status()
    }

    func requestAuthorization() {
        run("图库权限") { [self] in await ensureAuthorization("图库权限") }
    }

    @discardableResult
    private func ensureAuthorization(_ step: String) async -> Bool {
        var status = PhotosService.status()
        if status == .notDetermined {
            log.add(step, .info, "第一次请求读写权限，会弹系统授权框")
            status = await PhotosService.requestReadWrite()
        }
        authorization = status
        let usable = PhotosService.canUse(status)
        log.add(step, usable ? (status == .limited ? .warn : .ok) : .fail,
                "读写权限：\(PhotosService.name(of: status))",
                ["readWrite": .string(PhotosService.name(of: status)),
                 "addOnly": .string(PhotosService.name(of: PhotosService.addOnlyStatus()))])
        return usable
    }

    // MARK: 步骤调度

    func run(_ name: String, _ body: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        currentStep = name
        Task {
            await body()
            busy = false
            currentStep = nil
        }
    }

    func runStep(_ index: Int) {
        run(Self.stepNames[index - 1]) { [self] in _ = await perform(index) }
    }

    func runAll() {
        run("1–4 依次运行") { [self] in
            for index in 1...4 {
                guard await perform(index) else {
                    log.add("依次运行", .fail, "第 \(index) 步没成功，后面的不再运行")
                    return
                }
            }
            log.add("依次运行", .ok, "1–4 步全部结束")
        }
    }

    static let stepNames = ["1 检查原文件", "2 原地编辑写回", "3 读回检查", "4 复原", "5 存为新照片", "6 删除新照片"]

    private func perform(_ index: Int) async -> Bool {
        switch index {
        case 1: await stepInspectOriginal()
        case 2: await stepEditInPlace()
        case 3: await stepReadBack()
        case 4: await stepRevert()
        case 5: await stepSaveAsNew()
        default: await stepDeleteCreated()
        }
    }

    private func requireAsset(_ step: String) async -> PHAsset? {
        guard await ensureAuthorization(step) else { return nil }
        guard let id = assetIdentifier else {
            log.add(step, .fail, "还没选照片，或选择器没给出 PHAsset 标识")
            return nil
        }
        guard let asset = PhotosService.fetch(id) else {
            log.add(step, .fail, "按标识找不到这张照片（受限访问下，没勾选的照片取不到）",
                    ["identifier": .string(id), "authorization": .string(PhotosService.name(of: authorization))])
            return nil
        }
        return asset
    }

    // MARK: 1 检查原文件

    private func stepInspectOriginal() async -> Bool {
        let s = Self.stepNames[0]
        guard let item = pickerItem else {
            log.add(s, .fail, "请先选一张照片")
            return false
        }
        var ok = true

        // A. 选择器（保持原格式）给出的文件
        let start = Date()
        do {
            if let picked = try await item.loadTransferable(type: PickedFile.self) {
                let report = await Task.detached { ImageInspector.inspect(picked.url) }.value
                pickedURL = picked.url
                pickedReport = report
                pickedSummary = report.summary
                log.add(s, report.error == nil ? .ok : .fail, "选择器文件：\(report.summary)", [
                    "loadSeconds": .number(Date().timeIntervalSince(start)),
                    "report": .from(report),
                ])
            } else {
                log.add(s, .fail, "选择器没有返回文件")
                ok = false
            }
        } catch {
            log.add(s, .fail, "读取选择器文件失败：\(PhotosService.describe(error))")
            ok = false
        }

        // B. PhotoKit 里的原始资源
        guard let asset = await requireAsset(s) else { return false }
        log.add(s, .info, "PHAsset 属性", PhotosService.describe(asset))
        let resources = await PhotosService.exportResources(of: asset, to: LabPaths.work, prefix: "orig")
        for r in resources {
            let level: LogLevel = r.error == nil ? .info : .warn
            log.add(s, level, "资源 \(r.type) · \(r.uti) · \(r.originalFilename)：\(r.report?.summary ?? r.error ?? "非图像")", [
                "type": .string(r.type), "uti": .string(r.uti),
                "report": r.report.map { .from($0) } ?? .null,
                "error": .string(r.error ?? ""),
            ])
        }
        originalLibraryReport = resources.first(where: { $0.type == "photo" })?.report
            ?? resources.compactMap(\.report).first

        // C. 对比
        if let picked = pickedReport {
            let match = resources.first { $0.report?.sha256 == picked.sha256 }
            let library = originalLibraryReport
            let gainLost = (library?.hasAnyGainMap ?? false) && !picked.hasAnyGainMap
            let rawLost = (library?.isRAW ?? false) && !picked.isRAW
            let level: LogLevel = (match != nil) ? .ok : ((gainLost || rawLost) ? .fail : .warn)
            let text = match != nil
                ? "选择器文件与图库原始资源（\(match!.type)）字节完全一致"
                : "选择器文件与图库原始资源不一致" + (gainLost ? "，且增益图丢失" : "") + (rawLost ? "，且 RAW 变成了别的格式" : "")
            log.add(s, level, text, [
                "pickerSHA256": .string(picked.sha256 ?? ""),
                "matchedResource": .string(match?.type ?? "none"),
                "pickerHasGainMap": .bool(picked.hasAnyGainMap),
                "libraryHasGainMap": .bool(library?.hasAnyGainMap ?? false),
                "pickerIsRAW": .bool(picked.isRAW),
                "libraryIsRAW": .bool(library?.isRAW ?? false),
            ])
            if level == .fail { ok = false }
        }
        return ok
    }

    // MARK: 2 原地编辑写回

    private func stepEditInPlace() async -> Bool {
        let s = Self.stepNames[1]
        guard let asset = await requireAsset(s) else { return false }
        guard asset.canPerform(.content) else {
            log.add(s, .fail, "系统说这张照片不允许编辑内容（canPerform(.content) = false）", PhotosService.describe(asset))
            return false
        }
        let result = await PhotosService.requestEditingInput(for: asset, canHandle: true)
        guard let input = result.input, let source = input.fullSizeImageURL else {
            log.add(s, .fail, "requestContentEditingInput 没有给出输入文件", ["info": .object(result.info)])
            return false
        }
        log.add(s, .ok, "拿到编辑输入", PhotosService.describe(input).merging(["info": .object(result.info)]) { a, _ in a })
        let base = await Task.detached { ImageInspector.inspect(source) }.value
        editBaseReport = base
        log.add(s, .info, "编辑输入文件：\(base.summary)", ["report": .from(base)])

        // 探测各渲染类型的输出位置（用一次性的 output，不影响真正要提交的那个）
        let probe = PHContentEditingOutput(contentEditingInput: input)
        var probeResult: [String: JSONValue] = [:]
        for type in probe.supportedRenderedContentTypes {
            do {
                let url = try probe.renderedContentURL(for: type)
                probeResult[type.identifier] = .string("ok: \(url.lastPathComponent)")
            } catch {
                probeResult[type.identifier] = .string("error: \(PhotosService.describe(error))")
            }
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        log.add(s, .info, "系统支持的渲染类型：\(output.supportedRenderedContentTypes.map(\.identifier).joined(separator: ", "))", [
            "defaultRenderedContentType": .string(output.defaultRenderedContentType?.identifier ?? "nil"),
            "supportedRenderedContentTypes": .array(output.supportedRenderedContentTypes.map { .string($0.identifier) }),
            "perTypeURL": .object(probeResult),
            "defaultRenderedContentURL": .string(output.renderedContentURL.lastPathComponent),
            "chosenVariant": .string(variant.rawValue),
            "chosenType": .string(variant.contentType.identifier),
        ])

        let type = variant.contentType
        if !output.supportedRenderedContentTypes.contains(where: { $0.conforms(to: type) }) {
            log.add(s, .warn, "所选变体的类型 \(type.identifier) 不在系统支持列表里，仍然尝试")
        }
        let destination: URL
        do {
            destination = try output.renderedContentURL(for: type)
        } catch {
            log.add(s, .fail, "系统不给 \(type.identifier) 的输出位置：\(PhotosService.describe(error))")
            return false
        }

        // 渲染并写出
        let ev = exposure, variant = variant
        do {
            let report = try await Task.detached { () -> WriteReport in
                let image = try HDREditor.edited(from: source, exposure: ev, applyOrientation: !variant.keepsStoredOrientation)
                return try HDREditor.write(image, variant: variant, to: destination, gainMapSource: source)
            }.value
            let written = await Task.detached { ImageInspector.inspect(destination) }.value
            writtenReport = written
            let expectsGain = variant.expectsISOGainMap
            let gainOK = (!expectsGain || written.hasISOGainMap) && (variant != .heicCarriedGainMap || written.hasAnyGainMap)
            log.add(s, gainOK ? .ok : .warn, "写出渲染文件：\(written.summary)", [
                "write": .from(report), "report": .from(written),
                "note": .string(expectsGain && !written.hasISOGainMap
                                ? "输入没有增益图时 ImageIO 不会生成增益图；这不是图库的问题" : ""),
            ])
        } catch {
            log.add(s, .fail, "渲染或写出失败：\(error.localizedDescription)")
            return false
        }

        // adjustmentData
        let recipe = HDREditor.recipeData(exposure: ev, variant: variant, paddingBytes: paddingKB * 1024)
        lastRecipe = recipe
        output.adjustmentData = PHAdjustmentData(formatIdentifier: HDREditor.formatIdentifier,
                                                 formatVersion: HDREditor.formatVersion, data: recipe)
        log.add(s, .info, "adjustmentData：\(recipe.count) 字节", ["bytes": .number(Double(recipe.count))])

        log.add(s, .info, "提交修改，系统会弹出“修改”确认框，请点允许")
        do {
            try await PhotosService.commit(output, to: asset)
        } catch {
            log.add(s, .fail, "提交失败：\(PhotosService.describe(error))")
            return false
        }
        let refreshed = PhotosService.fetch(asset.localIdentifier)
        log.add(s, .ok, "原地编辑已提交", refreshed.map(PhotosService.describe) ?? [:])
        return true
    }

    // MARK: 3 读回检查

    private func stepReadBack() async -> Bool {
        let s = Self.stepNames[2]
        guard let asset = await requireAsset(s) else { return false }
        var ok = true
        log.add(s, .info, "PHAsset 属性", PhotosService.describe(asset))

        // a. 声明能处理我们的 adjustmentData：应得到配方和未调整的底图
        let handled = await PhotosService.requestEditingInput(for: asset, canHandle: true)
        if let input = handled.input {
            var details = PhotosService.describe(input)
            if let adjustment = input.adjustmentData {
                let same = lastRecipe.map { $0 == adjustment.data }
                let isOurs = adjustment.formatIdentifier == HDREditor.formatIdentifier
                details["recipeEqualsWritten"] = same.map { .bool($0) } ?? .null
                details["recipePreview"] = .string(String(decoding: adjustment.data.prefix(300), as: UTF8.self))
                log.add(s, isOurs && same != false ? .ok : .fail,
                        "adjustmentData 读回：\(adjustment.formatIdentifier) v\(adjustment.formatVersion)，\(adjustment.data.count) 字节，与写入内容\(same == true ? "一致" : (same == false ? "不一致" : "（本次运行没有写入记录，无法比较）"))", details)
                if !isOurs || same == false { ok = false }
            } else {
                log.add(s, .warn, "读不到 adjustmentData（可能还没编辑过，或写入时被丢弃）", details)
                ok = false
            }
            if let url = input.fullSizeImageURL {
                let report = await Task.detached { ImageInspector.inspect(url) }.value
                log.add(s, .info, "canHandle=true 时的输入文件（应是未调整底图）：\(report.summary)", ["report": .from(report)])
                if let original = originalLibraryReport {
                    log.add(s, .info, "底图与原始资源\(report.sha256 == original.sha256 ? "字节一致" : "字节不同")")
                }
            }
        } else {
            log.add(s, .fail, "canHandle=true 读不到编辑输入", ["info": .object(handled.info)])
            ok = false
        }

        // b. 不声明：系统给当前渲染结果
        let plain = await PhotosService.requestEditingInput(for: asset, canHandle: false)
        if let input = plain.input, let url = input.fullSizeImageURL {
            let report = await Task.detached { ImageInspector.inspect(url) }.value
            log.add(s, .info, "canHandle=false 时的输入文件（当前渲染结果）：\(report.summary)", [
                "report": .from(report),
                "hasAdjustmentData": .bool(input.adjustmentData != nil),
            ])
            judgeRendered(report, step: s)
        }

        // c. 全部资源
        let resources = await PhotosService.exportResources(of: asset, to: LabPaths.work, prefix: "after-edit", measureLuminance: true)
        for r in resources {
            log.add(s, r.error == nil ? .info : .warn, "资源 \(r.type) · \(r.uti)：\(r.report?.summary ?? r.error ?? "非图像")", [
                "type": .string(r.type), "report": r.report.map { .from($0) } ?? .null, "error": .string(r.error ?? ""),
            ])
            if r.type == "fullSizePhoto", let report = r.report { judgeRendered(report, step: s) }
        }

        // d. 其他 App 通过 PhotoKit 能拿到的当前图像数据
        let dataURL = LabPaths.work.appendingPathComponent("current-image-data")
        if let error = await PhotosService.currentImageData(of: asset, to: dataURL) {
            log.add(s, .warn, "requestImageDataAndOrientation 失败：\(error)")
        } else {
            let report = await Task.detached { ImageInspector.inspect(dataURL) }.value
            log.add(s, .info, "requestImageDataAndOrientation（当前版本）：\(report.summary)", ["report": .from(report)])
        }
        return ok
    }

    private func judgeRendered(_ report: ImageReport, step: String) {
        if let before = editBaseReport?.meanLuminance, let after = report.meanLuminance, before > 0 {
            let ratio = after / before
            let expected = pow(2, exposure)
            log.add(step, .info, String(format: "平均亮度变化 ×%.3f（理论 +%.1f EV ≈ ×%.3f，高光被压缩时会偏小）", ratio, exposure, expected), [
                "ratio": .number(ratio), "expected": .number(expected),
            ])
        }
        if let written = writtenReport {
            if written.hasAnyGainMap {
                if report.hasISOGainMap == written.hasISOGainMap && report.hasAppleHDRGainMap == written.hasAppleHDRGainMap {
                    log.add(step, .ok, "写入的增益图保住了（\(written.hasISOGainMap ? "ISO" : "Apple") 格式）")
                } else if report.hasAnyGainMap {
                    log.add(step, .warn, "增益图还在，但格式变了：写入 ISO=\(written.hasISOGainMap) Apple=\(written.hasAppleHDRGainMap)，读回 ISO=\(report.hasISOGainMap) Apple=\(report.hasAppleHDRGainMap)")
                } else {
                    log.add(step, .fail, "写入的增益图在图库里没有保住")
                }
            }
            if let wd = written.bitDepth, let rd = report.bitDepth, wd != rd {
                log.add(step, .warn, "位深变了：写入 \(wd) 位，读回 \(rd) 位")
            }
            if let wt = written.imageSourceType, let rt = report.imageSourceType, wt != rt {
                log.add(step, .warn, "文件类型变了：写入 \(wt)，读回 \(rt)")
            }
        }
    }

    // MARK: 4 复原

    private func stepRevert() async -> Bool {
        let s = Self.stepNames[3]
        guard let asset = await requireAsset(s) else { return false }
        guard asset.canPerform(.content) else {
            log.add(s, .fail, "系统不允许对这张照片做内容操作，无法复原")
            return false
        }
        log.add(s, .info, "调用 revertAssetContentToOriginal，系统可能弹确认框")
        do {
            try await PhotosService.revert(asset)
        } catch {
            log.add(s, .fail, "复原失败：\(PhotosService.describe(error))")
            return false
        }
        guard let refreshed = PhotosService.fetch(asset.localIdentifier) else { return false }
        var ok = true
        log.add(s, refreshed.hasAdjustments ? .fail : .ok, "复原后 hasAdjustments = \(refreshed.hasAdjustments)", PhotosService.describe(refreshed))
        if refreshed.hasAdjustments { ok = false }

        let input = await PhotosService.requestEditingInput(for: refreshed, canHandle: true)
        if let i = input.input {
            log.add(s, i.adjustmentData == nil ? .ok : .fail, "复原后 adjustmentData：\(i.adjustmentData == nil ? "已清除" : "仍然存在")", PhotosService.describe(i))
            if i.adjustmentData != nil { ok = false }
            if let url = i.fullSizeImageURL {
                let report = await Task.detached { ImageInspector.inspect(url) }.value
                let same = originalLibraryReport?.sha256.map { $0 == report.sha256 }
                log.add(s, same == false ? .warn : .ok, "复原后的输入文件：\(report.summary)；与第 1 步的原始资源\(same == true ? "字节一致" : (same == false ? "字节不同" : "（没有记录可比）"))", ["report": .from(report)])
            }
        }
        let resources = await PhotosService.exportResources(of: refreshed, to: LabPaths.work, prefix: "after-revert")
        for r in resources {
            log.add(s, .info, "资源 \(r.type) · \(r.uti)：\(r.report?.summary ?? r.error ?? "非图像")", ["report": r.report.map { .from($0) } ?? .null])
        }
        if let original = originalLibraryReport,
           let photo = resources.first(where: { $0.type == "photo" })?.report {
            let same = photo.sha256 == original.sha256
            log.add(s, same ? .ok : .fail, "photo 资源\(same ? "与编辑前字节一致，图库已恢复原状" : "与编辑前不一致")")
            if !same { ok = false }
        }
        log.add(s, .info, "请再到系统“照片”App 里打开这张照片，确认已经是原图，并看一眼“编辑”里有没有“还原”残留")
        return ok
    }

    // MARK: 5 存为新照片

    private func stepSaveAsNew() async -> Bool {
        let s = Self.stepNames[4]
        guard await ensureAuthorization(s) else { return false }
        guard let sourceURL = pickedURL, let picked = pickedReport else {
            log.add(s, .fail, "请先做第 1 步（需要选择器给出的文件做素材）")
            return false
        }
        var ok = true
        let ev = exposure, variant = variant
        let editedURL = LabPaths.work.appendingPathComponent("new-edited-\(UUID().uuidString.prefix(6)).\(variant.fileExtension)")
        do {
            _ = try await Task.detached { () -> WriteReport in
                let image = try HDREditor.edited(from: sourceURL, exposure: ev, applyOrientation: !variant.keepsStoredOrientation)
                return try HDREditor.write(image, variant: variant, to: editedURL, gainMapSource: sourceURL)
            }.value
        } catch {
            log.add(s, .fail, "渲染失败：\(error.localizedDescription)")
            return false
        }
        let editedReport = await Task.detached { ImageInspector.inspect(editedURL) }.value
        log.add(s, .info, "准备导入的编辑后文件：\(editedReport.summary)", ["report": .from(editedReport)])

        // 原文件原样导入作对照
        let controlName = "PhotosLab-control-" + sourceURL.lastPathComponent
        let controlType = UTType(filenameExtension: sourceURL.pathExtension) ?? .image
        let items: [(String, URL, UTType, String, ImageReport)] = [
            ("编辑后", editedURL, variant.contentType, "PhotosLab-edited." + variant.fileExtension, editedReport),
            ("原文件对照", sourceURL, controlType, controlName, picked),
        ]
        for (label, url, type, filename, expected) in items {
            log.add(s, .info, "导入“\(label)”，系统可能弹添加确认框")
            do {
                let created = try await PhotosService.create(fileURL: url, contentType: type, originalFilename: filename)
                createdIdentifiers.append(created.localIdentifier)
                log.add(s, .ok, "已创建新照片（\(label)）", ["localIdentifier": .string(created.localIdentifier)])
                guard let asset = PhotosService.fetch(created.localIdentifier) else {
                    log.add(s, .warn, "读不回新照片（可能只有“仅添加”权限，或受限访问下新照片不在可见范围）")
                    continue
                }
                let resources = await PhotosService.exportResources(of: asset, to: LabPaths.work, prefix: "new-\(label)", measureLuminance: false)
                for r in resources {
                    log.add(s, .info, "新照片资源 \(r.type) · \(r.uti)：\(r.report?.summary ?? r.error ?? "非图像")", ["report": r.report.map { .from($0) } ?? .null])
                }
                if let photo = resources.first(where: { $0.type == "photo" })?.report {
                    let same = photo.sha256 == expected.sha256
                    let gainKept = !expected.hasAnyGainMap || photo.hasAnyGainMap
                    let level: LogLevel = same ? .ok : (gainKept ? .warn : .fail)
                    log.add(s, level, "“\(label)”：导入后\(same ? "字节一致" : "字节不同")，增益图\(expected.hasAnyGainMap ? (gainKept ? "保留" : "丢失") : "（原本就没有）")", [
                        "expectedISO": .bool(expected.hasISOGainMap), "expectedApple": .bool(expected.hasAppleHDRGainMap),
                        "importedISO": .bool(photo.hasISOGainMap), "importedApple": .bool(photo.hasAppleHDRGainMap),
                    ])
                    if level == .fail { ok = false }
                }
            } catch {
                log.add(s, .fail, "导入“\(label)”失败：\(PhotosService.describe(error))")
                ok = false
            }
        }
        log.add(s, .warn, "测完请点“6 删除新照片”，或在“照片”App 里手动删除名为 PhotosLab-* 的照片，并清空“最近删除”")
        return ok
    }

    // MARK: 6 删除新照片

    private func stepDeleteCreated() async -> Bool {
        let s = Self.stepNames[5]
        guard !createdIdentifiers.isEmpty else {
            log.add(s, .info, "本次运行没有创建过新照片")
            return true
        }
        guard await ensureAuthorization(s) else { return false }
        log.add(s, .info, "删除 \(createdIdentifiers.count) 张新照片，系统会弹确认框")
        do {
            try await PhotosService.delete(identifiers: createdIdentifiers)
            log.add(s, .ok, "已删除（它们会进“最近删除”，30 天后才真正清除；想立刻清掉请在“照片”App 的“最近删除”里手动清空）")
            createdIdentifiers = []
            return true
        } catch {
            log.add(s, .fail, "删除失败或被取消：\(PhotosService.describe(error))")
            return false
        }
    }

    func clearTemporaryFiles() {
        LabPaths.clearWork()
        log.add("清理", .ok, "已清除临时文件")
    }
}

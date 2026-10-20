import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers

/// PhotoKit 的薄封装。这里每个函数都会碰真实图库，只在用户手动点按钮时调用。
enum PhotosService {
    // MARK: 授权

    static func status() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func addOnlyStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestReadWrite() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func name(of status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined（还没问过）"
        case .restricted: "restricted（系统限制）"
        case .denied: "denied（用户拒绝）"
        case .authorized: "authorized（完全访问）"
        case .limited: "limited（受限访问）"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    static func canUse(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    // MARK: 资产

    static func fetch(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func describe(_ asset: PHAsset) -> [String: JSONValue] {
        [
            "localIdentifier": .string(asset.localIdentifier),
            "mediaType": .number(Double(asset.mediaType.rawValue)),
            "mediaSubtypesRaw": .number(Double(asset.mediaSubtypes.rawValue)),
            "pixelWidth": .number(Double(asset.pixelWidth)),
            "pixelHeight": .number(Double(asset.pixelHeight)),
            "hasAdjustments": .bool(asset.hasAdjustments),
            "canEditContent": .bool(asset.canPerform(.content)),
            "canEditProperties": .bool(asset.canPerform(.properties)),
            "canDelete": .bool(asset.canPerform(.delete)),
            "sourceType": .number(Double(asset.sourceType.rawValue)),
        ]
    }

    static func name(of type: PHAssetResourceType) -> String {
        switch type {
        case .photo: "photo"
        case .video: "video"
        case .audio: "audio"
        case .alternatePhoto: "alternatePhoto"
        case .fullSizePhoto: "fullSizePhoto"
        case .fullSizeVideo: "fullSizeVideo"
        case .adjustmentData: "adjustmentData"
        case .adjustmentBasePhoto: "adjustmentBasePhoto"
        case .pairedVideo: "pairedVideo"
        case .fullSizePairedVideo: "fullSizePairedVideo"
        case .adjustmentBasePairedVideo: "adjustmentBasePairedVideo"
        case .adjustmentBaseVideo: "adjustmentBaseVideo"
        case .photoProxy: "photoProxy"
        @unknown default: "unknown(\(type.rawValue))"
        }
    }

    // MARK: 资源导出

    struct ExportedResource {
        var type: String
        var typeRaw: Int
        var uti: String
        var originalFilename: String
        var url: URL?
        var error: String?
        var report: ImageReport?
    }

    /// 把资产的所有资源写到目录里并逐个检查。图片类资源会做 ImageIO 检查。
    static func exportResources(of asset: PHAsset, to directory: URL, prefix: String,
                                measureLuminance: Bool = false) async -> [ExportedResource] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var out: [ExportedResource] = []
        for resource in PHAssetResource.assetResources(for: asset) {
            let typeName = name(of: resource.type)
            var item = ExportedResource(type: typeName, typeRaw: resource.type.rawValue,
                                        uti: resource.uniformTypeIdentifier,
                                        originalFilename: resource.originalFilename)
            let destination = directory.appendingPathComponent("\(prefix)-\(typeName)-\(resource.originalFilename)")
            try? FileManager.default.removeItem(at: destination)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            do {
                try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
                item.url = destination
                let isImage = UTType(resource.uniformTypeIdentifier)?.conforms(to: .image) ?? false
                if isImage {
                    item.report = ImageInspector.inspect(destination, measureLuminance: measureLuminance)
                }
            } catch {
                item.error = describe(error)
            }
            out.append(item)
        }
        return out
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code): \(e.localizedDescription)"
    }

    // MARK: 内容编辑

    struct EditingInputResult {
        var input: PHContentEditingInput?
        var info: [String: JSONValue]
    }

    /// `canHandle` 为真时，声明我们认识自己的 adjustmentData，系统就会给出未调整的底图。
    static func requestEditingInput(for asset: PHAsset, canHandle: Bool) async -> EditingInputResult {
        await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { data in
                canHandle && data.formatIdentifier == HDREditor.formatIdentifier
            }
            asset.requestContentEditingInput(with: options) { input, info in
                var summary: [String: JSONValue] = [:]
                for (key, value) in info {
                    summary[String(describing: key)] = JSONValue.from(any: value)
                }
                continuation.resume(returning: EditingInputResult(input: input, info: summary))
            }
        }
    }

    static func describe(_ input: PHContentEditingInput) -> [String: JSONValue] {
        var d: [String: JSONValue] = [
            "mediaType": .number(Double(input.mediaType.rawValue)),
            "contentType": .string(input.contentType?.identifier ?? "nil"),
            "fullSizeImageURL": .string(input.fullSizeImageURL?.lastPathComponent ?? "nil"),
            "fullSizeImageOrientation": .number(Double(input.fullSizeImageOrientation)),
            "hasAdjustmentData": .bool(input.adjustmentData != nil),
        ]
        if let adjustment = input.adjustmentData {
            d["adjustmentFormatIdentifier"] = .string(adjustment.formatIdentifier)
            d["adjustmentFormatVersion"] = .string(adjustment.formatVersion)
            d["adjustmentDataBytes"] = .number(Double(adjustment.data.count))
        }
        return d
    }

    static func commit(_ output: PHContentEditingOutput, to asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.contentEditingOutput = output
        }
    }

    static func revert(_ asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
        }
    }

    /// 系统当前对外给出的图像数据（相当于别的 App 通过 PhotoKit 拿到的版本）。
    static func currentImageData(of asset: PHAsset, to url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.version = .current
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, info in
                guard let data else {
                    continuation.resume(returning: "没有数据：\(info ?? [:])")
                    return
                }
                do {
                    try data.write(to: url)
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: String(describing: error))
                }
            }
        }
    }

    // MARK: 新建与删除

    struct CreatedAsset {
        var localIdentifier: String
    }

    static func create(fileURL: URL, contentType: UTType, originalFilename: String) async throws -> CreatedAsset {
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = originalFilename
            options.contentType = contentType
            options.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: fileURL, options: options)
            placeholderID = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let placeholderID else {
            throw NSError(domain: "PhotosLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "没拿到新照片的标识"])
        }
        return CreatedAsset(localIdentifier: placeholderID)
    }

    static func delete(identifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }
}

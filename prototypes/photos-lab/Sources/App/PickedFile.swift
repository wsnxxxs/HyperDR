import Foundation
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum LabPaths {
    /// 日志放在 App 的“文稿”目录（Mac 上在沙盒容器里，iPhone/iPad 上能在“文件”App 里看到）。
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 中间文件（选图副本、读回的资源）放在临时目录，可随时清理。
    static var work: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clearWork() {
        try? FileManager.default.removeItem(at: work)
    }
}

/// 选择器给出的文件。接收方式是“保持原格式”后落到我们自己的临时目录。
struct PickedFile: Transferable {
    let url: URL
    let receivedType: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let directory = LabPaths.work.appendingPathComponent("picked-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedFile(url: destination, receivedType: UTType(filenameExtension: destination.pathExtension)?.identifier ?? "unknown")
        }
    }
}

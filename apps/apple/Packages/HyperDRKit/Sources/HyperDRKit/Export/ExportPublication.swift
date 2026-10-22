import Foundation
import HyperDREngine

public struct ExportOutput: Codable, Sendable {
    public let input, output: String
    public let success, skipped: Bool
    public let message: String
    public let errorCode: String?
    public let errorDetail: JSONValue?
    public let detail: String?
    public let width, height: Int?
    /// Present for a framed export: `width`/`height` are then the canvas.
    public let frame: ReportFrame?

    public init(input: String, output: String, success: Bool, skipped: Bool,
                message: String, width: Int?, height: Int?, frame: ReportFrame? = nil,
                errorCode: String? = nil, detail: String? = nil, errorDetail: JSONValue? = nil) {
        self.input = input
        self.output = output
        self.success = success
        self.skipped = skipped
        self.message = message
        self.errorCode = errorCode
        self.errorDetail = errorDetail
        self.detail = detail
        self.width = width
        self.height = height
        self.frame = frame
    }
    private enum CodingKeys: String, CodingKey {
        case input, output, success, skipped, message, width, height, frame, detail
        case errorCode = "error_code"
        case errorDetail = "error_detail"
    }
}
public struct ExportPublication: Sendable {
    public let json: Data
    public let files: [ExportOutput]

    public init(json: Data, files: [ExportOutput]) {
        self.json = json
        self.files = files
    }
}

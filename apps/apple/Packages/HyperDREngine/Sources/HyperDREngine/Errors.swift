import Foundation
import HyperDREngineCore

public struct HyperDRError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let detail: String?
    public init(code: String, message: String, detail: String? = nil) {
        self.code = code; self.message = message; self.detail = detail
    }
    public var errorDescription: String? { "\(message) (\(code))" }
}

func checkStatus(_ status: Int32, _ error: UnsafeMutablePointer<hyperdr_error>?) throws {
    defer { if let error { hyperdr_error_free(error) } }
    guard status == 0 else {
        throw HyperDRError(
            code: error.flatMap { $0.pointee.code }.map { String(cString: $0) } ?? "out_of_memory",
            message: error.flatMap { $0.pointee.message }.map { String(cString: $0) } ?? "Engine call failed")
    }
}

func jsonResult(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                         UnsafeMutablePointer<UnsafeMutablePointer<hyperdr_error>?>) -> Int32) throws -> Data {
    var output: UnsafeMutablePointer<CChar>?
    var error: UnsafeMutablePointer<hyperdr_error>?
    let status = call(&output, &error)
    defer { if let output { hyperdr_string_free(output) } }
    try checkStatus(status, error)
    guard let output else { throw HyperDRError(code: "internal_error", message: "Missing engine JSON result") }
    return Data(bytes: output, count: strlen(output))
}

func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw HyperDRError(code: "internal_error", message: "Invalid engine JSON: \(error)") }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    do { return String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    catch { throw HyperDRError(code: "invalid_options", message: "Invalid request JSON: \(error)") }
}

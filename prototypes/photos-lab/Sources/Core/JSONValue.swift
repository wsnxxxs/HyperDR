import Foundation

/// 日志里用的最小 JSON 值类型。
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// 把任意 Codable 值转成 JSONValue。
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let v = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string(String(describing: value))
        }
        return v
    }

    /// 把 CoreFoundation / Foundation 返回的松散字典转成 JSONValue，无法识别的用 description。
    static func from(any value: Any?) -> JSONValue {
        guard let value else { return .null }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        if let d = value as? Data { return .string("<\(d.count) bytes>") }
        if let a = value as? [Any] { return .array(a.map { from(any: $0) }) }
        if let d = value as? [String: Any] { return .object(d.mapValues { from(any: $0) }) }
        if let d = value as? [AnyHashable: Any] {
            var o: [String: JSONValue] = [:]
            for (k, v) in d { o[String(describing: k)] = from(any: v) }
            return .object(o)
        }
        return .string(String(describing: value))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    /// 方便在界面上显示的缩进文本。
    var prettyText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}

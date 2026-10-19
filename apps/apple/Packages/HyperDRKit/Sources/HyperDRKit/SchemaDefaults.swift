import Foundation
import HyperDREngine

/// The engine schema's defaults, read once. The schema is the only place a
/// default is written down (D1); the controls and choices here take their
/// initial values from it by schema key.
enum SchemaDefaults {
    private static let values: [String: JSONValue] = {
        // A pure computation on the linked engine; it cannot fail in a working build.
        guard let schema = try? Engine.schema() else {
            preconditionFailure("The engine schema could not be read")
        }
        return Dictionary(uniqueKeysWithValues: schema.settings.compactMap { setting in
            setting.default.map { (setting.key, $0) }
        })
    }()

    static func number(_ key: String) -> Double {
        guard case .number(let value)? = values[key] else {
            preconditionFailure("The schema has no numeric default for \(key)")
        }
        return value
    }

    static func string(_ key: String) -> String {
        guard case .string(let value)? = values[key] else {
            preconditionFailure("The schema has no text default for \(key)")
        }
        return value
    }

    /// The `hdrRange` control's default. Negative means automatic headroom,
    /// which is what the schema's `headroom` default says; a number would be
    /// the fixed range.
    static var headroomRange: Double {
        if case .string("auto")? = values["headroom"] { return -1 }
        return number("headroom_max")
    }
}

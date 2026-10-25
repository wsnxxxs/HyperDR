import Foundation

/// How a RAW source had to be opened when Apple's native decoder could not
/// develop the original file. Nil means the system developed it directly.
public enum SourceCompatibility: String, Sendable, Codable {
    case convertedDNG = "converted-dng"
    case embeddedPreview = "embedded-preview"
}

import Foundation

/// Stable mixer order, shared by the picker, controls and renderer.
public enum HSLBand: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
}
public enum HSLComponent: String, CaseIterable, Sendable {
    case hue, saturation, luminance
}

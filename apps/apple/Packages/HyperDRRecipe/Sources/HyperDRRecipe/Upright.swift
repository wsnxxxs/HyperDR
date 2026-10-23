import Foundation

/// What an automatic upright corrects (the crop pane's Auto). Every mode
/// replaces the straightening and perspective it solves for and keeps the
/// turns, mirror and ratio.
public enum UprightMode: String, CaseIterable, Hashable, Sendable {
    /// Balanced: levels the photo and corrects the perspective the lines show
    /// clearly, without over-correcting.
    case auto
    /// Straightening only.
    case level
    /// Straightening and the vertical perspective (converging verticals).
    case vertical
    /// Straightening and both perspectives.
    case full
}

import AppKit
import SwiftUI

/// Motion (CSS `--ease`, `--duration-*`). One curve, three durations: `fast`
/// for hover and press feedback, `standard` for state changes, `slow` for
/// surfaces arriving. Under Reduce Motion nothing animates.
public enum Motion {
    public static let fast: TimeInterval = 0.12
    public static let standard: TimeInterval = 0.2
    public static let slow: TimeInterval = 0.32

    /// cubic-bezier(0.16, 1, 0.3, 1): a quick start that settles gently.
    public static func ease(_ duration: TimeInterval = standard) -> Animation {
        .timingCurve(0.16, 1, 0.3, 1, duration: duration)
    }
}

private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let duration: TimeInterval
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Motion.ease(duration), value: value)
    }
}

public extension View {
    /// `.animation(Motion.ease(duration), value:)` that stands still under Reduce Motion.
    func hdrAnimation<Value: Equatable>(_ duration: TimeInterval = Motion.standard, value: Value) -> some View {
        modifier(MotionModifier(duration: duration, value: value))
    }
}

/// `withAnimation` counterpart for state changes made in actions.
@MainActor
public func withHDRAnimation<Result>(_ duration: TimeInterval = Motion.standard, _ body: () throws -> Result) rethrows -> Result {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return try body() }
    return try withAnimation(Motion.ease(duration), body)
}

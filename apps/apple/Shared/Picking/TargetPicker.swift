import CoreGraphics
import Foundation
import Observation

/// The eyedropper that adjusts from the photograph (adjust-tools §2.2, §6.3):
/// while it is on, pressing a pixel samples it, and dragging up or down
/// edits the control the sample points at, until the pointer or finger lifts,
/// as one undo step. The curve eyedropper and the colour mixer's are this
/// class with their own `begin`. The white balance eyedropper is a click, not
/// a drag, and stays `WhiteBalancePicker`.
///
/// The mode stays on after a drag, so one press follows another; the button
/// again, Esc, another photo, the crop pane or a locked editor ends it.
@MainActor @Observable final class TargetPicker {
    /// What a press starts: the edit the drag performs.
    struct Drag {
        /// The drag's rise in canvas points (up is positive), from the press.
        var apply: (CGFloat) -> Void
        var finish: () -> Void
        /// What the pick says about the sample, by control (the curve's input).
        var marks: [String: Double] = [:]
    }

    /// The canvas is waiting for a press.
    private(set) var isActive = false
    /// A press is down.
    private(set) var isPressing = false
    /// The last sample's marks.
    private(set) var marks: [String: Double] = [:]

    /// A canvas point on the photo as shown, 0…1 from the top left; nil outside it.
    @ObservationIgnored var photoPoint: (CGPoint) -> CGPoint? = { _ in nil }
    /// Samples the photo at a point and returns the edit to drag with; nil
    /// when there is nothing to edit there.
    @ObservationIgnored var begin: (CGPoint) async throws -> Drag? = { _ in nil }
    /// Called when the mode turns on, so a host can end the others.
    @ObservationIgnored var onActivate: () -> Void = {}

    @ObservationIgnored private var origin: CGPoint?
    @ObservationIgnored private var rise: CGFloat = 0
    @ObservationIgnored private var drag: Drag?
    @ObservationIgnored private var released = false
    @ObservationIgnored private var sampling: Task<Void, Never>?
    /// Counts presses; a sample still being read from an earlier one finds it changed.
    @ObservationIgnored private var generation = 0

    func toggle() { isActive ? cancel() : start() }

    func start() {
        guard !isActive else { return }
        onActivate()
        isActive = true
    }

    /// Ends the mode; a press down is finished first, keeping what it did.
    func cancel() {
        release()
        isActive = false
    }

    /// Another photo, the crop pane or a locked editor: ends the mode and
    /// forgets the marks.
    func reset() {
        generation += 1
        drag?.finish()
        end()
        isActive = false
        marks = [:]
    }

    /// The press at `point` (canvas points).
    func press(at point: CGPoint) {
        guard isActive, !isPressing, let fraction = photoPoint(point) else { return }
        isPressing = true
        origin = point
        rise = 0
        released = false
        drag = nil
        generation += 1
        let token = generation
        let begin = begin
        sampling = Task { @MainActor in
            let started = try? await begin(fraction)
            guard token == generation, isPressing || released else { started?.finish(); return }
            guard let started else { end(); return }
            drag = started
            marks = started.marks
            started.apply(rise)
            if released { finish() }
        }
    }

    /// The pointer or finger moved to `point` with the press down.
    func move(to point: CGPoint) {
        guard isPressing, let origin else { return }
        rise = origin.y - point.y
        drag?.apply(rise)
    }

    /// The pointer or finger lifted.
    func release() {
        guard isPressing else { return }
        released = true
        if drag != nil { finish() }
        // Else the sample is still being read: it finishes the press when it arrives.
    }

    private func finish() {
        drag?.finish()
        end()
    }

    private func end() {
        drag = nil
        origin = nil
        isPressing = false
        released = false
    }
}

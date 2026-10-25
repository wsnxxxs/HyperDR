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

    /// One press, from its own origin: its rise, its edit once the sample is
    /// in, and whether the finger has lifted. A press whose sample is still
    /// being read when the finger lifts keeps its own state, so the next
    /// press cannot overwrite it.
    private final class Gesture {
        let origin: CGPoint
        let generation: Int
        var rise: CGFloat = 0
        var drag: Drag?
        var released = false
        init(origin: CGPoint, generation: Int) { self.origin = origin; self.generation = generation }
    }

    /// The press that is down.
    @ObservationIgnored private var held: Gesture?
    /// The last sample queued: each press samples after the one before has
    /// applied and finished, so each drag is its own step in order.
    @ObservationIgnored private var sampling: Task<Void, Never>?
    /// Counts resets; a sample still being read from an earlier press finds it
    /// changed after one.
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
        held?.drag?.finish()
        held?.drag = nil
        held = nil
        isPressing = false
        isActive = false
        marks = [:]
    }

    /// The press at `point` (canvas points).
    func press(at point: CGPoint) {
        guard isActive, !isPressing, let fraction = photoPoint(point) else { return }
        let gesture = Gesture(origin: point, generation: generation)
        held = gesture
        isPressing = true
        let begin = begin
        let previous = sampling
        sampling = Task { @MainActor in
            await previous?.value
            guard gesture.generation == generation else { return }
            let started = try? await begin(fraction)
            guard gesture.generation == generation else { started?.finish(); return }
            guard let started else {
                if held === gesture { held = nil; isPressing = false }
                return
            }
            gesture.drag = started
            marks = started.marks
            started.apply(gesture.rise)
            if gesture.released { started.finish(); gesture.drag = nil }
        }
    }

    /// The pointer or finger moved to `point` with the press down.
    func move(to point: CGPoint) {
        guard isPressing, let gesture = held else { return }
        gesture.rise = gesture.origin.y - point.y
        gesture.drag?.apply(gesture.rise)
    }

    /// The pointer or finger lifted.
    func release() {
        guard let gesture = held else { return }
        gesture.released = true
        held = nil
        isPressing = false
        // A sample still being read finishes the press when it arrives.
        if let drag = gesture.drag { drag.finish(); gesture.drag = nil }
    }
}

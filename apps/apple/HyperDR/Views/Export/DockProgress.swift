import AppKit
import Observation

/// What the Dock icon shows of an export (M3 §5.5): a bar along the foot of
/// the icon while it runs, and one jump of the icon when it ends while the
/// app is in the background. It is the only place a user in another app can
/// see that the export is still going.
@MainActor final class DockProgress {
    /// The bar: nothing, a fraction of the width, or (with no estimate yet)
    /// half of it, moving.
    enum Bar: Equatable {
        case none, determinate(Double), indeterminate
    }

    static func bar(phase: ExportState.Phase, estimate: ExportEstimate?) -> Bar {
        guard [.preparing, .running, .finishing, .saving].contains(phase) else { return .none }
        guard let estimate else { return .indeterminate }
        return .determinate(min(max(estimate.fraction, 0), ExportProgressFraction.cap))
    }

    /// The icon jumps once when an export ends by itself while the app is in
    /// the background, whether it worked or failed; not for a stop the user
    /// asked for.
    static func shouldBounce(from old: ExportState.Phase, to new: ExportState.Phase, appIsActive: Bool) -> Bool {
        let wasRunning = [.preparing, .running, .finishing, .saving].contains(old)
        return wasRunning && (new == .succeeded || new == .failed) && !appIsActive
    }

    private let model: EditorModel
    private let tile: NSDockTile
    private let view = DockProgressView()
    private var lastPhase: ExportState.Phase
    private var ticker: Task<Void, Never>?

    init(model: EditorModel, tile: NSDockTile = NSApp.dockTile) {
        self.model = model
        self.tile = tile
        lastPhase = model.export.phase
    }

    /// Starts following the model's export.
    func start() {
        track()
        update()
    }

    private func track() {
        withObservationTracking {
            _ = model.export.phase
            _ = model.export.isStopping
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.track()
            }
        }
    }

    private func update() {
        let phase = model.export.phase
        if Self.shouldBounce(from: lastPhase, to: phase, appIsActive: NSApp.isActive) {
            NSApp.requestUserAttention(.informationalRequest)
        }
        lastPhase = phase
        refresh()
        if Self.bar(phase: phase, estimate: nil) != .none {
            if ticker == nil {
                ticker = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        self?.refresh()
                    }
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func refresh() {
        let bar = Self.bar(phase: model.export.phase, estimate: model.export.estimate(at: Date()))
        if bar == .none {
            tile.contentView = nil
        } else {
            view.bar = bar
            view.tick += 1
            tile.contentView = view
        }
        tile.display()
    }
}

/// The share of the bar an unfinished export may fill: never full.
enum ExportProgressFraction { static let cap = 0.99 }

/// The dock tile's content: the app icon with the progress bar over its foot.
private final class DockProgressView: NSView {
    var bar = DockProgress.Bar.none
    var tick = 0

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage.draw(in: bounds)
        let track = NSRect(x: 12, y: 10, width: bounds.width - 24, height: 12)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6).fill()
        let fill: NSRect
        switch bar {
        case .none: return
        case .determinate(let fraction): fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        case .indeterminate:
            let width = track.width / 2
            let travel = track.width - width
            let phase = CGFloat(tick % 8) / 7
            fill = NSRect(x: track.minX + travel * (phase < 0.5 ? phase * 2 : 2 - phase * 2), y: track.minY,
                          width: width, height: track.height)
        }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
    }
}

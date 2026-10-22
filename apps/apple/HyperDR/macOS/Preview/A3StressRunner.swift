#if DEBUG
import Foundation
import HyperDRRecipe
import os

/// S12's input-rate measurement, connected to the real editor/canvas instead
/// of its historical fake-service window. Only the user opts in at launch;
/// this code never opens/activates a window or posts input events.
@MainActor enum A3StressRunner {
    enum Mode: String { case steps, drag }
    private static var armed = false
    private static let logger = Logger(subsystem: "com.hyperdr.HyperDR", category: "PreviewStress")
    /// NSArgumentDomain contains launch options only; never consult persistent
    /// preferences or registered defaults for a runner that changes edits.
    struct Configuration {
        let mode: Mode
        let edge: Int?
    }
    static func configuration(defaults: UserDefaults = .standard) -> Configuration? {
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let value = arguments["HDRA3Stress"] as? String, let mode = Mode(rawValue: value) else { return nil }
        let edge = arguments["HDRA3Edge"].flatMap { Int(String(describing: $0)) }
        return Configuration(mode: mode, edge: edge.flatMap { [640, 2048].contains($0) ? $0 : nil })
    }
    static var edge: Int? { configuration()?.edge }

    static func arm(model: EditorModel) {
        guard !armed, let mode = configuration()?.mode else { return }
        armed = true
        Task { [weak model] in
            // Opening is done by the user through the normal scoped workflow.
            // Waiting here does not change startup restore or commandeer focus.
            while !Task.isCancelled {
                guard let model else { return }
                if model.document?.phase == .ready, !model.isEditingLocked { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard let model, let photo = model.photo,
                  let exposure = Adjustments.declaration("tone.exposure") else { return }
            let editor = model.editor
            let current = editor.recipe.conditionValue(exposure.id)?.numberValue ?? 0
            let lower = current - 0.5, upper = current + 0.5
            model.viewMode = .edited
            logger.notice("A3Stress mode=\(mode.rawValue, privacy: .public) event=begin ns=\(DispatchTime.now().uptimeNanoseconds, privacy: .public)")
            if mode == .drag { editor.editingChanged(exposure, true) }
            defer {
                if mode == .drag, model.photo == photo { editor.editingChanged(exposure, false) }
                logger.notice("A3Stress mode=\(mode.rawValue, privacy: .public) event=end ns=\(DispatchTime.now().uptimeNanoseconds, privacy: .public)")
            }
            let count = mode == .drag ? 3000 : 30
            for index in 0..<count {
                guard !Task.isCancelled, model.photo == photo, !model.isEditingLocked else { return }
                // S12's 100Hz sustained input, through the editor's own pacing.
                var recipe = editor.recipe
                recipe.setValue(.number(lower + Double(index % 30 + 1) / 31 * (upper - lower)), for: exposure.id)
                editor.setRecipe(recipe)
                if mode == .steps {
                    let deadline = ContinuousClock.now + .seconds(60)
                    while editor.frame?.request.recipe != editor.recipe {
                        guard ContinuousClock.now < deadline, model.photo == photo, !Task.isCancelled else {
                            logger.error("A3Stress event=render_timeout"); return
                        }
                        do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                    }
                } else {
                    do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                }
            }
        }
    }
}
#endif

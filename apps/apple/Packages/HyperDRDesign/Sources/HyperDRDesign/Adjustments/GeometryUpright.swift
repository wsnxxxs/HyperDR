import HyperDRRecipe
import SwiftUI

/// The crop pane's Auto as the hosts hand it to their controls: whether an
/// analysis runs, what the last one could not do, and how to start one. The
/// editor behind it lives in the app, so the controls take it as values.
@MainActor public struct GeometryUpright {
    /// Why the last Auto left the geometry as it was.
    public enum Notice: Sendable {
        case noLines, failed
    }

    /// The mode being analysed; nil when none runs.
    public var analyzing: UprightMode?
    public var notice: Notice?
    public var run: @MainActor (UprightMode) -> Void

    public init(analyzing: UprightMode?, notice: Notice?, run: @escaping @MainActor (UprightMode) -> Void) {
        self.analyzing = analyzing
        self.notice = notice
        self.run = run
    }

    /// The modes the button's menu offers; its primary action is `.auto`.
    public static let menuModes: [UprightMode] = [.level, .vertical, .full]

    public static let symbol = "wand.and.sparkles"

    public static func name(_ mode: UprightMode) -> Text {
        switch mode {
        case .auto: Text("crop.upright.auto", bundle: .module)
        case .level: Text("crop.upright.level", bundle: .module)
        case .vertical: Text("crop.upright.vertical", bundle: .module)
        case .full: Text("crop.upright.full", bundle: .module)
        }
    }

    public static func text(_ notice: Notice) -> Text {
        switch notice {
        case .noLines: Text("crop.upright.noLines", bundle: .module)
        case .failed: Text("crop.upright.failed", bundle: .module)
        }
    }

    /// The menu's items, one per mode in `menuModes`.
    @ViewBuilder public var menuItems: some View {
        ForEach(Self.menuModes, id: \.self) { mode in
            Button { run(mode) } label: { Self.name(mode) }
        }
    }
}

import Foundation
import HyperDRDesign
import Observation
import SwiftUI

/// Which adjustment groups and which sections inside them (the curve, the
/// colour mixer, the grading) are open in the inspector. One record for the
/// app, kept across photos, the crop pane and launches: what was left open
/// is open again, and nothing opens or folds by itself because a photo was
/// opened or a value changed.
@MainActor @Observable final class InspectorDisclosure {
    static let shared = InspectorDisclosure()

    var groups: Set<AdjustmentGroupID> {
        didSet { save(groups.map(\.rawValue), Self.groupsKey) }
    }

    var sections: Set<AdjustmentSections.Kind> {
        didSet { save(sections.map(\.rawValue), Self.sectionsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    static let groupsKey = "HyperDRInspectorOpenGroups"
    static let sectionsKey = "HyperDRInspectorOpenSections"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        groups = (defaults.stringArray(forKey: Self.groupsKey)).map { Set($0.compactMap(AdjustmentGroupID.init(rawValue:))) }
            ?? AdjustmentInspector.initiallyExpanded
        sections = Set((defaults.stringArray(forKey: Self.sectionsKey) ?? []).compactMap(AdjustmentSections.Kind.init(rawValue:)))
    }

    private func save(_ values: [String], _ key: String) {
        defaults.set(values.sorted(), forKey: key)
    }

    var groupsBinding: Binding<Set<AdjustmentGroupID>> {
        Binding(get: { self.groups }, set: { self.groups = $0 })
    }

    var sectionsBinding: Binding<Set<AdjustmentSections.Kind>> {
        Binding(get: { self.sections }, set: { self.sections = $0 })
    }
}

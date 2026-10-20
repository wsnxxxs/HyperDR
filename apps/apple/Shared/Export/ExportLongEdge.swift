import HyperDRKit

/// The custom format's size, for the Mac and iOS hosts (p7-3c-export §1.3 B):
/// the original size, a common long edge smaller than the photo, or a typed
/// one; and, when memory blocks the export, the largest long edge that fits.
nonisolated enum ExportLongEdge {
    /// The long edges offered besides the original size.
    static let presets = [3840, 2560, 2160, 1080]

    /// What the size picker offers for a photo whose long edge is `photo`:
    /// the original size (nil), the presets smaller than the photo, and the
    /// current limit when it is none of those (typed, or the memory budget's).
    static func choices(photo: Int?, current: Int?) -> [Int?] {
        var edges = presets.filter { edge in photo.map { edge < $0 } ?? true }
        if let current, !edges.contains(current) { edges.append(current) }
        return [nil] + edges.sorted(by: >)
    }

    /// A requested long edge as the format keeps it: a positive number below
    /// the photo's; anything else is the original size (nil).
    static func normalized(_ edge: Int?, photo: Int?) -> Int? {
        guard let edge, edge > 0, photo.map({ edge < $0 }) ?? true else { return nil }
        return edge
    }

    /// The largest long edge the memory budget admits, when memory is what
    /// blocks the plan and a smaller size would fit.
    static func admissible(_ plan: ExportPlan) -> Int? {
        guard memoryBlocker(plan) != nil else { return nil }
        return plan.memory.maxAdmissibleLongEdge
    }

    /// The plan's memory blocker, if memory blocks it.
    static func memoryBlocker(_ plan: ExportPlan) -> ExportBlocker? {
        plan.blockers.first { $0.code == "export_memory_exceeded" }
    }
}

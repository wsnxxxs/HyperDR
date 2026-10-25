import Darwin
import Foundation
import HyperDRKit

/// The process footprint while an export runs, sampled every 10 ms and kept as
/// the highest value seen in each part of the run, with how long the part took,
/// so a log line can be held against the plan's estimate for that stage. The
/// kernel's own lifetime peak would also count opening the photo in the editor.
nonisolated final class ExportFootprint: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = RecipeExportStage.preparing.rawValue
    private var peaks: [(stage: String, bytes: Int, start: ContinuousClock.Instant, end: ContinuousClock.Instant)] = []
    private let timer: DispatchSourceTimer

    init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hyperdr.HyperDR.footprint", qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// The part the next samples belong to: Kit's stage, with AVIF's cells
    /// apart from its rows ("encoding-cells"). Kit's progress reaches the main
    /// actor a little after a part begins; its first samples can land in the
    /// one before it.
    func enter(_ progress: RecipeExportProgress) {
        lock.withLock { stage = progress.stage.rawValue + (progress.cells != nil ? "-cells" : "") }
    }

    /// "developing 418 MiB 5.5 s, rendering 483 MiB 8.3 s, encoding 623 MiB 18.0 s, …".
    func finish() -> String {
        timer.cancel()
        sample()
        return lock.withLock {
            peaks.map { peak in
                let elapsed = peak.start.duration(to: peak.end).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                return "\(peak.stage) \(peak.bytes / 1_048_576) MiB \(String(format: "%.1f", seconds)) s"
            }.joined(separator: ", ")
        }
    }

    private func sample() {
        guard let bytes = Self.current() else { return }
        let now = ContinuousClock.now
        lock.withLock {
            if let last = peaks.indices.last, peaks[last].stage == stage {
                peaks[last].bytes = max(peaks[last].bytes, bytes)
                peaks[last].end = now
            } else {
                if !peaks.isEmpty { peaks[peaks.count - 1].end = now }
                peaks.append((stage, bytes, now, now))
            }
        }
    }

    /// `phys_footprint`, the figure the system holds against the app's limit.
    static func current() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }
}

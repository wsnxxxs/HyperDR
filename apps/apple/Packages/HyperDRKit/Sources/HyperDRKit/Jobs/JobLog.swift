import Foundation

/// Unicode scalar offsets match Python's character offsets, including emoji.
struct JobLog: Sendable {
    let limit: Int
    private(set) var start = 0
    private var retained: [Unicode.Scalar] = []
    var end: Int { start + retained.count }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        retained.append(contentsOf: text.unicodeScalars)
        let drop = max(0, retained.count - max(0, limit))
        if drop > 0 { retained.removeFirst(drop); start += drop }
    }

    func read(_ offset: Int) -> (text: String, truncated: Bool) {
        let index = offset <= start ? 0 : min(retained.count, offset - start)
        return (String(String.UnicodeScalarView(retained[index...])), start > 0 || offset < start)
    }
}

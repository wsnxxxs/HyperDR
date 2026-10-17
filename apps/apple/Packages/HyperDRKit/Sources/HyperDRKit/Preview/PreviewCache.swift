import Foundation

/// Small LRU used for native preview frames. The frames own page-aligned
/// buffers, so the byte budget is the important bound; the entry count keeps
/// the two most recent slider states cheap to revisit.
actor PreviewCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let value: Value
        let bytes: Int
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var totalBytes = 0

    init(entries: Int, bytes: Int) {
        maxEntries = max(0, entries)
        maxBytes = max(0, bytes)
    }

    var count: Int { entries.count }

    func get(_ key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return entry.value
    }

    func put(_ value: Value, bytes: Int, for key: Key) {
        let size = max(0, bytes)
        guard maxEntries > 0, maxBytes > 0, size <= maxBytes else { return }
        if let old = entries.removeValue(forKey: key) {
            totalBytes -= old.bytes
            if let index = order.firstIndex(of: key) { order.remove(at: index) }
        }
        entries[key] = Entry(value: value, bytes: size)
        order.append(key)
        totalBytes += size
        while entries.count > maxEntries || totalBytes > maxBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { totalBytes -= removed.bytes }
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
    }

    func removeAll(where predicate: @Sendable (Key) -> Bool) {
        for key in order where predicate(key) {
            if let removed = entries.removeValue(forKey: key) { totalBytes -= removed.bytes }
        }
        order.removeAll { predicate($0) }
    }
}

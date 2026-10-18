import Foundation

/// Small LRU used for native preview frames. The frames own page-aligned
/// buffers, so the byte budget is the important bound; the entry count keeps
/// the two most recent slider states cheap to revisit. Entries put with
/// `counted: false` (model gains) share the byte budget but not the entry
/// count, so slider frames do not push them out.
actor PreviewCache<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let value: Value
        let bytes: Int
        let counted: Bool
    }

    private let maxEntries: Int
    private let maxBytes: Int
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private(set) var totalBytes = 0
    private var countedEntries = 0

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

    func put(_ value: Value, bytes: Int, for key: Key, counted: Bool = true) {
        let size = max(0, bytes)
        guard maxEntries > 0, maxBytes > 0, size <= maxBytes else { return }
        if entries[key] != nil { remove(key) }
        entries[key] = Entry(value: value, bytes: size, counted: counted)
        order.append(key)
        totalBytes += size
        if counted { countedEntries += 1 }
        while countedEntries > maxEntries || totalBytes > maxBytes {
            let victim = totalBytes > maxBytes ? order.first
                : order.first { entries[$0]?.counted == true }
            guard let victim else { break }
            remove(victim)
        }
    }

    private func remove(_ key: Key) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        totalBytes -= removed.bytes
        if removed.counted { countedEntries -= 1 }
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
        totalBytes = 0
        countedEntries = 0
    }

    func removeAll(where predicate: @Sendable (Key) -> Bool) {
        for key in order where predicate(key) {
            if let removed = entries.removeValue(forKey: key) {
                totalBytes -= removed.bytes
                if removed.counted { countedEntries -= 1 }
            }
        }
        order.removeAll { predicate($0) }
    }
}

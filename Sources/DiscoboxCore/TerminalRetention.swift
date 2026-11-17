import Foundation

/// Least-recently-used order of retained terminal identities. It only decides
/// which keys to release; the owner tears them down and protects what is shown.
public struct RecencyList<Key: Hashable> {
    /// Oldest first.
    public private(set) var order: [Key] = []
    public init() {}

    /// Marks `key` as the most recently used, adding it if needed.
    public mutating func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
    public mutating func remove(_ key: Key) { order.removeAll { $0 == key } }
    public mutating func removeAll() { order.removeAll() }

    /// The oldest `eligible` keys beyond the newest `limit` eligible ones,
    /// oldest first. Ineligible keys (shown, focused, already released) are
    /// never returned and do not count against the limit.
    public func overflow(limit: Int, eligible: (Key) -> Bool) -> [Key] {
        let candidates = order.filter(eligible)
        return Array(candidates.prefix(max(0, candidates.count - max(0, limit))))
    }
}

/// Text kept per key within a total UTF-8 byte budget. Storing a value makes it
/// the newest; the oldest values are dropped until the total fits. A single
/// value larger than the whole budget keeps only its newest bytes.
public struct BoundedTextStore<Key: Hashable> {
    public let budget: Int
    public private(set) var byteCount = 0
    private var values: [Key: String] = [:]
    /// Oldest first.
    private var order: [Key] = []

    public init(budget: Int) { self.budget = max(0, budget) }

    public subscript(key: Key) -> String? { values[key] }
    public var keys: [Key] { order }

    public mutating func set(_ text: String, for key: Key) {
        removeValue(forKey: key)
        let kept = Self.suffix(text, bytes: budget)
        while !order.isEmpty, byteCount + kept.utf8.count > budget { removeValue(forKey: order[0]) }
        values[key] = kept
        order.append(key)
        byteCount += kept.utf8.count
    }

    @discardableResult public mutating func removeValue(forKey key: Key) -> String? {
        guard let value = values.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        byteCount -= value.utf8.count
        return value
    }

    public mutating func removeAll() { values.removeAll(); order.removeAll(); byteCount = 0 }

    /// The newest `bytes` of `text`, never starting inside a UTF-8 sequence.
    static func suffix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var tail = text.utf8.suffix(bytes)
        while let first = tail.first, first & 0xC0 == 0x80 { tail = tail.dropFirst() }
        return String(decoding: tail, as: UTF8.self)
    }
}

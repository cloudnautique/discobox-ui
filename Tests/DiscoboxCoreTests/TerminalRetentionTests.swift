import Testing
@testable import DiscoboxCore

@Test func recencyReleasesOnlyTheOldestHiddenKeysBeyondTheLimit() {
    var recency = RecencyList<String>()
    for key in ["a", "b", "c", "d"] { recency.touch(key) }
    recency.touch("a") // Returning to a terminal makes it the newest.
    #expect(recency.order == ["b", "c", "d", "a"])
    #expect(recency.overflow(limit: 2) { _ in true } == ["b", "c"])
    // Shown keys are protected and do not use up the hidden allowance.
    #expect(recency.overflow(limit: 2) { $0 != "b" } == ["c"])
    #expect(recency.overflow(limit: 2) { $0 == "d" }.isEmpty)
    #expect(recency.overflow(limit: 0) { $0 != "a" } == ["b", "c", "d"])
    #expect(recency.overflow(limit: -1) { _ in true } == ["b", "c", "d", "a"])
    recency.remove("c")
    #expect(recency.order == ["b", "d", "a"])
    recency.removeAll()
    #expect(recency.overflow(limit: 0) { _ in true }.isEmpty)
}

@Test func boundedTextDropsOldestValuesBeyondItsBudget() {
    var store = BoundedTextStore<String>(budget: 10)
    store.set("1234", for: "a")
    store.set("5678", for: "b")
    #expect(store.byteCount == 8)
    store.set("xyz", for: "c") // 11 bytes: the oldest value goes.
    #expect(store["a"] == nil)
    #expect(store.keys == ["b", "c"])
    #expect(store.byteCount == 7)
    store.set("12", for: "b") // Replacing refreshes and re-counts.
    #expect(store.keys == ["c", "b"])
    #expect(store.byteCount == 5)
    #expect(store.removeValue(forKey: "c") == "xyz")
    #expect(store.removeValue(forKey: "c") == nil)
    #expect(store.byteCount == 2)
    store.removeAll()
    #expect(store.byteCount == 0 && store.keys.isEmpty)
}

@Test func boundedTextKeepsTheNewestBytesOfAnOversizedValueOnCharacterBoundaries() {
    var store = BoundedTextStore<Int>(budget: 4)
    store.set("ab", for: 1)
    store.set("old-é日本", for: 2) // 12 bytes; é is 2 bytes, 日 and 本 are 3.
    #expect(store[1] == nil)
    #expect(store[2] == "本")
    #expect(store.byteCount == 3)
    #expect(store.byteCount <= store.budget)
    #expect(BoundedTextStore<Int>.suffix("abcdef", bytes: 3) == "def")
    #expect(BoundedTextStore<Int>.suffix("abc", bytes: 3) == "abc")
}

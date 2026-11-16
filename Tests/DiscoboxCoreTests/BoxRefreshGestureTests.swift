import Testing
@testable import DiscoboxCore

@Test func horizontalRowSwipesNeverTriggerRefreshWithVerticalDrift() {
    for direction in [-1.0, 1.0] {
        var gesture = BoxRefreshGesture()
        for _ in 0..<40 { #expect({ !gesture.update(x: 12 * direction, y: 6, atTop: true) }()) }
        // A late vertical tail belongs to the same horizontal gesture.
        for _ in 0..<20 { #expect({ !gesture.update(x: 0, y: 12, atTop: true) }()) }
        gesture.reset()
        #expect({ gesture.update(x: 1, y: 100, atTop: true) }())
    }
}

@Test func verticalRefreshNeedsTopThresholdAndOnlyFiresOncePerGesture() {
    var gesture = BoxRefreshGesture()
    #expect({ !gesture.update(x: 0, y: 120, atTop: false) }())
    #expect({ !gesture.update(x: 1, y: 45, atTop: true) }())
    #expect({ gesture.update(x: 1, y: 45, atTop: true) }())
    #expect({ !gesture.update(x: 0, y: 150, atTop: true) }())
    gesture.reset()
    #expect({ !gesture.update(x: 0, y: -120, atTop: true) }())
    #expect({ !gesture.update(x: 0, y: 80, atTop: true) }())
    #expect({ gesture.update(x: 0, y: 10, atTop: true) }())
}

import Foundation
import Observation
import Testing
@testable import DiscoboxCore

@MainActor @Observable private final class Readiness {
    var loading = true
    var unrelated = 0
}

@MainActor @Test func observedConditionResumesWhenTheStateChanges() async {
    let model = Readiness()
    let waiting = Task { await ObservedCondition.wait(timeout: .seconds(30)) { !model.loading } }
    await Task.yield()
    model.unrelated += 1
    model.loading = false
    #expect(await waiting.value)
}

@MainActor @Test func observedConditionReturnsImmediatelyWhenAlreadySatisfied() async {
    let model = Readiness()
    model.loading = false
    #expect(await ObservedCondition.wait(timeout: .zero) { !model.loading })
}

@MainActor @Test func observedConditionTimesOut() async {
    let model = Readiness()
    let started = Date()
    #expect(await !ObservedCondition.wait(timeout: .milliseconds(50)) { !model.loading })
    #expect(Date().timeIntervalSince(started) < 5)
}

@MainActor @Test func observedConditionStopsWaitingWhenCancelled() async {
    let model = Readiness()
    let waiting = Task { await ObservedCondition.wait(timeout: .seconds(30)) { !model.loading } }
    await Task.yield()
    waiting.cancel()
    #expect(await !waiting.value)
    model.loading = false
}

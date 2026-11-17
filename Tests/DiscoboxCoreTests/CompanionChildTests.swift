import Foundation
import Testing
@testable import DiscoboxCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Line: Decodable, Sendable, Equatable { let n: Int }

/// Fixtures never wait for stdin EOF: on Linux a sibling child can inherit the
/// pipe, so they are stopped by signals (as `close()` escalates) instead. Linux
/// Foundation also spawns children with the test thread's blocked signal mask,
/// so there SIGTERM is often held and only the SIGKILL escalation stops them.
private func fixture(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("companion-child-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("companion")
    try writeExecutable("#!/bin/sh\n\(body)\n", to: executable)
    return executable
}
private func describe(_ event: CompanionChild<Line>.Event) -> String {
    switch event {
    case .message(let line): "\(line.n)"
    case .invalidLine: "invalid"
    case .ended(let ending): "ended:\(ending)"
    }
}
private func processGone(_ pid: Int32, within seconds: Double = 5) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if kill(pid, 0) != 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@Test func companionChildDeliversBoundedLinesInOrderAndReportsExit() async throws {
    let child = CompanionChild<Line>(executable: try fixture(#"printf '{"n":1}\n{"n":2}\nnot json\n{"n":3}\n'"#), arguments: ["--forward"])
    try child.start()
    var seen: [String] = []
    for await event in child.events { seen.append(describe(event)) }
    #expect(seen == ["1", "2", "invalid", "3", "ended:exited"])
    // EOF can precede the exit being reaped; after close it is never running.
    child.close(); child.close()
    #expect(!child.isRunning)
}

@Test func companionChildPassesArgumentsUnchanged() async throws {
    let child = CompanionChild<Line>(executable: try fixture(#"[ "$1" = "--desktop" ] && [ "$2" = "a b" ] && printf '{"n":7}\n'"#), arguments: ["--desktop", "a b"])
    try child.start()
    var seen: [String] = []
    for await event in child.events { seen.append(describe(event)) }
    #expect(seen == ["7", "ended:exited"])
}

@Test func companionChildClosesAChildWhoseLineExceedsTheBound() async throws {
    let child = CompanionChild<Line>(executable: try fixture("""
    printf '{"n":1}\\n'
    head -c 4096 /dev/zero | tr '\\0' a
    exec sleep 30
    """), arguments: [], maxLineBytes: 100)
    try child.start()
    let pid = child.processIdentifier
    var seen: [String] = []
    for await event in child.events { seen.append(describe(event)) }
    #expect(seen == ["1", "ended:lineTooLong"])
    #expect(await processGone(pid))
}

@Test func companionChildCloseEscalatesToKillAndEndsEventsSilently() async throws {
    // Ignores SIGTERM; only SIGKILL stops it.
    let child = CompanionChild<Line>(executable: try fixture("""
    trap '' TERM
    printf '{"n":1}\\n'
    while :; do sleep 0.05; done
    """), arguments: [], killAfter: .milliseconds(200))
    try child.start()
    let pid = child.processIdentifier
    var events = child.events.makeAsyncIterator()
    #expect(await events.next().map(describe) == "1")
    child.close()
    #expect(await events.next() == nil)
    #expect(!child.isRunning)
    #expect(await processGone(pid))
    child.close()
    #expect(throws: CancellationError.self) { try child.start() }
}

@Test func droppingACompanionChildTerminatesIt() async throws {
    var child: CompanionChild<Line>? = CompanionChild<Line>(executable: try fixture("""
    printf '{"n":1}\\n'
    exec sleep 30
    """), arguments: [])
    try child?.start()
    let pid = try #require(child?.processIdentifier)
    var events = try #require(child?.events).makeAsyncIterator()
    #expect(await events.next().map(describe) == "1")
    child = nil
    #expect(await processGone(pid))
    #expect(await events.next() == nil)
}

@Test func companionChildThatCannotLaunchIsClosed() throws {
    let child = CompanionChild<Line>(executable: URL(fileURLWithPath: "/nonexistent/companion-\(UUID().uuidString)"), arguments: [])
    #expect(throws: (any Error).self) { try child.start() }
    #expect(!child.isRunning)
}


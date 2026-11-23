import Foundation
import DiscoboxCore

enum EditorCommand {
    struct Result: Sendable {
        let status: Int32
        let text: String
    }

    static func arguments(_ editor: BoxEditor, app: URL, profile: ConnectionProfile, project: String, boxID: String) -> [String] {
        ["--auto-start-server=false", "--server", profile.endpoint, "--project", project, "tools", editor.rawValue,
         "--program", editor.launcher(in: app).path, "discobox:///" + boxID]
    }

    // Editor terminals inherit this environment. Supply the user's CLI state
    // and normal shell tools, leaving app credentials and routing overrides out.
    static func environment(for profile: ConnectionProfile) -> [String: String] {
        let allowed = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG", "SSH_AUTH_SOCK",
                       "XDG_STATE_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME"]
        var env = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        if profile.isRemote && !profile.relayURLs.isEmpty { env["DISCOBOX_IROH_RELAY_URLS"] = profile.relayURLs }
        return env
    }

    static func run(_ executable: URL, arguments: [String], profile: ConnectionProfile) async throws -> Result {
        let env = environment(for: profile)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Swift.Result { try execute(executable, arguments, env) })
            }
        }
    }

    private static func execute(_ executable: URL, _ arguments: [String], _ env: [String: String]) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = env
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let fd = reader.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw DiscoboxError("Could not read the Discobox CLI output.") }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // The editor may inherit the writer. Drain available bytes and finish
        // when the CLI exits, even if that editor keeps the pipe open.
        func drain() {
            for _ in 0..<16 {
                let count = read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                output.append(contentsOf: buffer.prefix(count))
                if output.count > 8192 { output.removeFirst(output.count - 8192) }
            }
        }
        while process.isRunning {
            drain()
            if ContinuousClock.now >= deadline {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw DiscoboxError("The Discobox CLI timed out. Check the editor before trying again.")
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        drain()
        return Result(status: process.terminationStatus, text: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

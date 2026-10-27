import Foundation

public enum WorkspaceCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case tools, changes, files, approvals, audit, agent, previousTerminal, nextTerminal, newShell, services, boxes, previousBox, nextBox, focus, refresh, help, disconnect
    public var id: Self { self }
    public var title: String {
        switch self {
        case .tools: "Open tools"
        case .changes: "Review changes"
        case .files: "Show files"
        case .approvals: "Pending requests"
        case .audit: "Show audit trail"
        case .agent: "Show agent"
        case .previousTerminal: "Previous terminal"
        case .nextTerminal: "Next terminal"
        case .newShell: "Open shell"
        case .services: "Show services"
        case .boxes: "Choose a box"
        case .previousBox: "Previous box"
        case .nextBox: "Next box"
        case .focus: "Maximize / restore agent"
        case .refresh: "Refresh workspace"
        case .help: "Show commands"
        case .disconnect: "Disconnect"
        }
    }
    public var defaultBinding: String {
        switch self {
        case .tools: "o"
        case .changes: "v"
        case .files: "f"
        case .approvals: "!"
        case .audit: "A"
        case .agent: "a, 0"
        case .previousTerminal: "h, left"
        case .nextTerminal: "l, right"
        case .newShell: "s"
        case .services: "S 0"
        case .boxes: "d"
        case .previousBox: "["
        case .nextBox: "]"
        case .focus: "z"
        case .refresh: "r"
        case .help: "?"
        case .disconnect: "q"
        }
    }
}

public struct CommandBindings: Codable, Equatable, Sendable {
    public var leader: String
    public var overrides: [String: String]
    public init(leader: String = "ctrl+a", overrides: [String: String] = [:]) {
        self.leader = leader; self.overrides = overrides
    }
    public subscript(command: WorkspaceCommand) -> String {
        get { overrides[command.rawValue] ?? command.defaultBinding }
        set { overrides[command.rawValue] = newValue }
    }
    public func sequences(for command: WorkspaceCommand) -> [[String]] {
        self[command].split(separator: ",", omittingEmptySubsequences: true).map {
            $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }.filter { !$0.isEmpty }
    }
    public var validationError: String? {
        guard leader.hasPrefix("ctrl+"), leader.count == 6, let letter = leader.last, ("a"..."z").contains(String(letter)) else {
            return "Choose a Control-letter leader."
        }
        var all: [([String], String)] = []
        for command in WorkspaceCommand.allCases {
            for sequence in sequences(for: command) {
                guard sequence.count <= 3 else { return "Use at most three keys for \(command.title)." }
                for token in sequence {
                    guard token != leader, token != "escape", token != ",",
                          token.count == 1 || ["left", "right", "up", "down", "tab", "enter", "space"].contains(token) else {
                        return "Invalid or reserved key ‘\(token)’ in \(command.title)."
                    }
                    if ["1","2","3","4","5","6","7","8","9"].contains(token), sequence.count == 1 {
                        return "Digits 1–9 select terminals and are reserved."
                    }
                }
                if let conflict = all.first(where: { $0.0.starts(with: sequence) || sequence.starts(with: $0.0) }) {
                    return "\(command.title) conflicts with \(conflict.1)."
                }
                all.append((sequence, command.title))
            }
        }
        return nil
    }
    public var literalLeader: String {
        String(UnicodeScalar(UInt32(leader.last!.asciiValue! - 96))!)
    }
}

/// Pure routing policy. Unknown sequences and cancelled prefixes never leak
/// into the remote prompt. A second leader sends that leader literally.
public struct LeaderRouter: Sendable {
    public enum Result: Equatable, Sendable {
        case pass, pending, cancelled, unknown, literal(String), command(WorkspaceCommand), terminal(Int)
    }
    public private(set) var sequence: [String]? = nil
    public init() {}
    public mutating func cancel() { sequence = nil }
    public mutating func key(_ token: String, bindings: CommandBindings) -> Result {
        guard var sequence else {
            guard token == bindings.leader else { return .pass }
            self.sequence = []; return .pending
        }
        if token == "escape" { cancel(); return .cancelled }
        if token == bindings.leader { cancel(); return .literal(bindings.literalLeader) }
        if sequence.isEmpty, let number = Int(token), (1...9).contains(number) { cancel(); return .terminal(number) }
        sequence.append(token)
        for command in WorkspaceCommand.allCases {
            if bindings.sequences(for: command).contains(sequence) { cancel(); return .command(command) }
        }
        if WorkspaceCommand.allCases.contains(where: { command in bindings.sequences(for: command).contains { $0.starts(with: sequence) } }) {
            self.sequence = sequence; return .pending
        }
        cancel(); return .unknown
    }
}

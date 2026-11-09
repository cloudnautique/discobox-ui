import Foundation

extension Sandbox {
    public var runningWarning: String? {
        guard isRunning, let message = runtime.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        return message
    }

    public var upgradeAvailable: Bool { runtime.upgrade?.available == true && BoxAction.upgrade.isAvailable(for: self) }

    public var isRepairing: Bool {
        !isArchived && !isDeleted && (runtime.displayState ?? runtime.state) == "repairing"
    }

    public var needsRepair: Bool {
        // Repair being offered is not evidence of failure: the server accepts
        // it on healthy boxes too. Display state also takes precedence over an
        // old failed generation while a repair is landing.
        !isArchived && !isDeleted && ["failed", "error"].contains(runtime.displayState ?? runtime.state)
    }

    public var repairTooltip: String? {
        if isRepairing { return "Repair in progress. Discobox is rebuilding this box while keeping its workspace data." }
        guard needsRepair else { return nil }
        let reason = runtime.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction: String
        if runtime.errorReason == "image_unavailable" && upgradeAvailable {
            instruction = "The pinned image is unavailable. Right-click this box and choose Upgrade… to rebuild on the current harness."
        } else {
            instruction = "Right-click this box and choose Repair… to rebuild it while keeping its workspace data."
        }
        return ["Needs repair.", reason?.isEmpty == false ? reason : nil, instruction].compactMap { $0 }.joined(separator: "\n")
    }

    public var upgradeTooltip: String? {
        guard upgradeAvailable else { return nil }
        return "Upgrade available. Right-click this box and choose Upgrade… to update its harness and runtime."
    }
}

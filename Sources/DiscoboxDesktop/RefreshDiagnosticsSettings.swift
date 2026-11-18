import SwiftUI
import DiscoboxCore

struct RefreshDiagnosticsSettings: View {
    @Environment(Connections.self) private var connections
    @AppStorage("DiscoboxDisableTerminalRecovery") private var pauseRecovery = false
    @AppStorage("DiscoboxDisableAutomaticGuestReads") private var disableGuestReads = false

    var body: some View {
        @Bindable var connections = connections
        Form {
            Section("Automatic refresh") {
                Toggle("Manual refresh for polled data", isOn: $connections.refreshPolicy.manual)
                Text("Manual mode pauses scheduled reads, including approval checks. Box events continue to arrive. Use ⌘R to refresh the workspace and open the approval inbox to check requests.")
                    .font(.caption).foregroundStyle(.secondary)
                let paused = connections.refreshPolicy.manual || GuestReadDiagnostics.automaticReadsDisabled
                Toggle("Pause terminal and service inventory reads", isOn: paused ? .constant(true) : $connections.refreshPolicy.pauseDetails)
                    .disabled(paused)
                Toggle("Pause harness usage reads", isOn: paused ? .constant(true) : $connections.refreshPolicy.pauseUsage)
                    .disabled(paused)
            }
            Section("Terminal recovery") {
                Toggle("Pause automatic terminal reconnect after relaunch", isOn: $pauseRecovery)
                Text(GuestReadDiagnostics.recoveryDisabled ? "Automatic terminal reconnect is paused for this launch." : "Automatic terminal reconnect is enabled for this launch.")
                    .font(.caption).foregroundStyle(.secondary)
                if GuestReadDiagnostics.automaticReadsDisabled {
                    Text("The launch override pauses guest detail reads, usage collection and terminal recovery until relaunch.")
                    if disableGuestReads { Button("Clear launch override for next launch") { disableGuestReads = false } }
                }
            }
            Section("Scheduled companion reads this session") {
                ForEach(connections.sessions) { host in
                    LabeledContent(host.profile.displayName) {
                        let reads = host.readMetrics
                        Text("\(reads.inFlight) in flight · \(reads.finished) finished · \(reads.cancelled) cancelled")
                            .monospacedDigit()
                    }
                }
                Text("Counts cover this app’s scheduled read helpers. Explicit actions and live streams have separate lifetimes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Restore normal refresh") {
                connections.refreshPolicy = RefreshPolicy()
                pauseRecovery = false
                disableGuestReads = false
            }
        }.formStyle(.grouped)
    }
}

struct RefreshOverrideBadge: View {
    @Environment(Connections.self) private var connections
    @AppStorage("DiscoboxDisableTerminalRecovery") private var pauseRecovery = false
    @AppStorage("DiscoboxDisableAutomaticGuestReads") private var disableGuestReads = false
    @State private var showing = false

    var body: some View {
        if connections.refreshPolicy != RefreshPolicy() || GuestReadDiagnostics.recoveryDisabled || pauseRecovery {
            Button { showing.toggle() } label: {
                Label(connections.refreshPolicy.manual ? "Manual refresh" : "Refresh overrides", systemImage: "pause.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 8) {
                    if connections.refreshPolicy.manual { Text("Scheduled reads and approval checks are paused. Box events remain active.") }
                    else {
                        if connections.refreshPolicy.pauseDetails || GuestReadDiagnostics.automaticReadsDisabled { Text("Automatic terminal and service inventory reads are paused.") }
                        if connections.refreshPolicy.pauseUsage || GuestReadDiagnostics.automaticReadsDisabled { Text("Automatic harness usage reads are paused.") }
                    }
                    if GuestReadDiagnostics.recoveryDisabled { Text("Relaunch to apply changes to terminal recovery.") }
                    else if pauseRecovery { Text("Automatic terminal recovery will pause after relaunch.") }
                    Button("Restore normal refresh") {
                        connections.refreshPolicy = RefreshPolicy()
                        pauseRecovery = false
                        disableGuestReads = false
                        showing = false
                    }
                }.padding().frame(width: 285, alignment: .leading)
            }
        }
    }
}

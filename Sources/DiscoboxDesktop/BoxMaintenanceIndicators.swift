import SwiftUI
import DiscoboxCore

/// Shared by sidebar and keyboard chooser so maintenance means the same thing
/// wherever a box is listed. These indicators never trigger a rebuild on click.
struct BoxMaintenanceIndicators: View {
    let box: Sandbox

    var body: some View {
        HStack(spacing: 7) {
            if let tooltip = box.repairTooltip {
                Image(systemName: box.needsRepair ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
                    .foregroundStyle(box.needsRepair ? Color.red : .orange)
                    .help(tooltip)
                    .accessibilityLabel(box.needsRepair ? "Needs repair" : "Repair in progress")
                    .accessibilityHint(tooltip)
                    .accessibilityIdentifier("box.maintenance.repair")
            }
            if let tooltip = box.upgradeTooltip {
                Image(systemName: "arrow.up.circle")
                    .foregroundStyle(DiscoboxAppearance.accent)
                    .help(tooltip)
                    .accessibilityLabel("Upgrade available")
                    .accessibilityHint(tooltip)
                    .accessibilityIdentifier("box.maintenance.upgrade")
            }
        }.font(.system(size: 12, weight: .medium)).fixedSize()
    }
}

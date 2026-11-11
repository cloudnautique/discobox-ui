import SwiftUI
import DiscoboxCore

struct BoxActivityFilters: View {
    @Binding var selection: BoxActivityFilter?
    let needsYou: Int
    let working: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(BoxActivityFilter.allCases) { filter in
                let count = filter == .needsYou ? needsYou : working
                let selected = selection == filter
                let attention = filter == .needsYou && count > 0
                Button { selection = selected ? nil : filter } label: {
                    HStack(spacing: 5) {
                        if selected { Image(systemName: "checkmark").font(.system(size: 8, weight: .semibold)) }
                        else if filter == .needsYou { Image(systemName: "hand.raised").font(.system(size: 10)) }
                        Text(filter.title)
                        Text("\(count)").monospacedDigit().fontWeight(attention ? .semibold : .regular)
                    }.font(.system(size: 10)).padding(.horizontal, 9).frame(height: 27)
                        .foregroundStyle(selected ? Color.primary : attention ? DiscoboxAppearance.activityAttention : .secondary)
                        .background(selected ? DiscoboxAppearance.selection : attention ? DiscoboxAppearance.activityAttention.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? DiscoboxAppearance.accent : DiscoboxAppearance.border.opacity(0.65), lineWidth: 0.6))
                }.buttonStyle(.borderless)
                    .accessibilityLabel(filter.title)
                    .accessibilityValue("\(count) boxes" + (selected ? ", filter selected" : ""))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("boxes.filter." + filter.rawValue)
                    .help("\(filter.title): \(count) boxes within your current filters. Click again to clear. The current box stays visible.")
            }
            Spacer(minLength: 0)
        }
    }
}

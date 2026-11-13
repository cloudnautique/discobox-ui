import SwiftUI
import DiscoboxCore

struct BoxStatusLight: View {
    let indicator: BoxIndicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var color: Color {
        switch indicator.state {
        case .on: DiscoboxAppearance.success
        case .off, .unavailable: .secondary.opacity(0.55)
        case .attention: DiscoboxAppearance.activityAttention
        case .error: DiscoboxAppearance.activityFailure
        }
    }
    var body: some View {
        ZStack {
            if indicator.state == .unavailable {
                Circle().strokeBorder(color, lineWidth: 1).frame(width: 6, height: 6)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            if indicator.isWorking {
                if reduceMotion || scenePhase != .active {
                    WorkingArc().stroke(color, style: .init(lineWidth: 1.25, lineCap: .round))
                        .frame(width: 14, height: 14)
                } else {
                    WorkingOrbit(color: color)
                }
            }
        }.frame(width: 18, height: 18).accessibilityHidden(true)
    }
}

/// Isolated from the row so rotation never ticks the list or its data model.
private struct WorkingOrbit: View {
    let color: Color
    @State private var rotating = false
    var body: some View {
        WorkingArc().stroke(color, style: .init(lineWidth: 1.25, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 1.35).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
            .onDisappear { rotating = false }
    }
}

private struct WorkingArc: Shape {
    func path(in rect: CGRect) -> Path {
        Circle().trim(from: 0, to: 0.64).path(in: rect)
    }
}

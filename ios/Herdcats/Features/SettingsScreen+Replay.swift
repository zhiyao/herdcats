import SwiftUI

#if DEBUG
struct OnboardingReplaySection: View {
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                Label("Replay Onboarding", systemImage: "arrow.counterclockwise.circle")
            }
            .listRowBackground(Theme.groupedRowBackground)
        } header: {
            Text("Debug")
                .font(.jost(.footnote))
        }
    }
}

struct DebugOnboardingReplayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var replayModel = AppModel(autoConnectOnLaunch: false)

    var body: some View {
        ConnectView(replay: true)
            .environment(replayModel)
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    Button("Exit Replay") { dismiss() }
                        .buttonStyle(.herdrSecondary(fullWidth: false))
                        .accessibilityIdentifier("exit-onboarding-replay")
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 8)
                .background(Theme.backgroundGradient)
            }
            .onDisappear {
                Task { await replayModel.disconnect() }
            }
    }
}
#endif

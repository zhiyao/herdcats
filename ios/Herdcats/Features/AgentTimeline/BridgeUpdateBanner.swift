import SwiftUI

/// Non-blocking, dismissible notice that a newer Herdcats Bridge exists for
/// the connected host. It only opens the existing setup sheet; it never installs.
struct BridgeUpdateBanner: View {
    let prompt: BridgeUpdatePrompt
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var canInstall: Bool { prompt.available.verifiedInstaller != nil }

    var body: some View {
        NoticeBar {
            Image(systemName: "arrow.up.circle")
                .accessibilityHidden(true)
            Text("Herdcats Bridge \(prompt.available.version) is available")
                .font(.jost(.subheadline, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            NoticeAction(title: canInstall ? "Update" : "Details", action: onOpen)
                .font(.jost(.subheadline, weight: .semibold))
                .accessibilityIdentifier("bridge-update-open")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("bridge-update-dismiss")
        }
        .accessibilityIdentifier("bridge-update-banner")
    }
}

import SwiftUI

/// Replaces the input dock on the unfocused slot of a split: the pane keeps
/// streaming output, and tapping the strip moves typing here.
struct PaneOutputOnlyStrip: View {
    @Environment(\.paneSlotActions) private var slotActions

    var body: some View {
        Button {
            slotActions?.focus()
        } label: {
            Text("Output only · tap to type here")
                .font(.jost(.footnote))
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle.continuous(DesignSystem.CornerRadius.sm)
                        .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityHint("Moves typing to this pane")
        .accessibilityIdentifier("pane-output-only-strip")
    }
}

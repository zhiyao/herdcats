import SwiftUI

// MARK: - Open actions (row menus)

/// "Open on Left", "Open on Right" and "Replace Focused Pane" for one row.
struct PaneOpenAction: Identifiable {
    let title: LocalizedStringKey
    let systemImage: String
    let identifier: String
    let perform: () -> Void

    var id: String { identifier }

    static func actions(for ref: PaneRef, layout: Binding<PaneLayout>) -> [PaneOpenAction] {
        [
            PaneOpenAction(title: "Open on Left", systemImage: "rectangle.lefthalf.filled", identifier: "open-left") {
                layout.wrappedValue.open(ref, in: .left)
            },
            PaneOpenAction(title: "Open on Right", systemImage: "rectangle.righthalf.filled", identifier: "open-right") {
                layout.wrappedValue.open(ref, in: .right)
            },
            PaneOpenAction(title: "Replace Focused Pane", systemImage: "arrow.left.arrow.right", identifier: "open-replace") {
                layout.wrappedValue.openInFocused(ref)
            },
        ]
    }
}

// MARK: - L / R badge

extension View {
    /// Marks a list row that is open in a slot while split. The focused
    /// slot's badge is filled.
    func paneSlotBadge(_ slot: PaneLayout.Slot?, focused: PaneLayout.Slot) -> some View {
        modifier(PaneSlotBadgeModifier(slot: slot, isFocused: slot == focused))
    }
}

private struct PaneSlotBadgeModifier: ViewModifier {
    let slot: PaneLayout.Slot?
    let isFocused: Bool

    func body(content: Content) -> some View {
        if let slot {
            content
                .overlay(alignment: .topTrailing) {
                    Text(slot == .left ? "L" : "R")
                        .font(.jost(10, weight: .bold))
                        .foregroundStyle(isFocused ? Theme.onPrimary : Theme.accent)
                        .frame(width: 16, height: 16)
                        .background(isFocused ? Theme.accent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.accent, lineWidth: 1))
                        .offset(y: -4)
                        .accessibilityHidden(true)
                }
                .accessibilityValue(slot == .left ? "Open on left" : "Open on right")
        } else {
            content
        }
    }
}

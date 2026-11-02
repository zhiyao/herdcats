import SwiftUI

// MARK: - Per-slot environment

private struct PaneIsFocusedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct PaneSlotActionsKey: EnvironmentKey {
    static let defaultValue: PaneSlotActions? = nil
}

/// What a pane's toolbar can do to the slot that holds it.
struct PaneSlotActions {
    let slot: PaneLayout.Slot
    let isSplit: Bool
    let split: () -> Void
    let replace: () -> Void
    let swap: () -> Void
    let fullWidth: () -> Void
    let close: () -> Void
    /// Moves focus (and typing) to this slot.
    let focus: () -> Void
}

/// In the compact stack while split: the pane that is open in the other slot,
/// and how to bring it forward. Lets the pane switcher offer it without
/// knowing about `PaneLayout`.
struct PanePartner {
    let ref: PaneRef
    let focus: () -> Void
}

private struct PanePartnerKey: EnvironmentKey {
    static let defaultValue: PanePartner? = nil
}

extension EnvironmentValues {
    var panePartner: PanePartner? {
        get { self[PanePartnerKey.self] }
        set { self[PanePartnerKey.self] = newValue }
    }

    /// Whether this pane owns the input surface. Only one split slot does;
    /// a lone pane, or one outside the split view, is always focused.
    var paneIsFocused: Bool {
        get { self[PaneIsFocusedKey.self] }
        set { self[PaneIsFocusedKey.self] = newValue }
    }

    var paneSlotActions: PaneSlotActions? {
        get { self[PaneSlotActionsKey.self] }
        set { self[PaneSlotActionsKey.self] = newValue }
    }
}

// MARK: - Two-pane detail

/// The split view's detail column: one pane, or two side by side with a
/// draggable divider. The column has one system navigation bar, so while
/// split each pane draws its own header (`PaneHeaderBar`).
struct TwoPaneDetail<Content: View>: View {
    @Binding var layout: PaneLayout
    let memory: OpenPaneMemory
    /// Opens the pane picker for a slot (wired up by the pane-choosing UI).
    var pick: (PaneLayout.Slot) -> Void = { _ in }
    @ViewBuilder let content: (PaneRef) -> Content

    static var dividerWidth: CGFloat { 12 }

    /// The ratio while the divider is being dragged; committed, snapped, on release.
    @State private var dragRatio: Double?

    var body: some View {
        GeometryReader { proxy in
            let isSplit = layout.isSplit
            let usable = max(proxy.size.width - Self.dividerWidth, 0)
            let ratio = dragRatio ?? layout.ratio
            let leftWidth = isSplit ? usable * ratio : proxy.size.width
            HStack(spacing: 0) {
                // The left slot keeps its place in the stack across split and
                // unsplit, so opening a second pane doesn't rebuild the first.
                if let left = layout.left {
                    slot(.left, left)
                        .frame(width: leftWidth)
                }
                if isSplit, let right = layout.right {
                    PaneSplitDivider(
                        ratio: ratio,
                        usableWidth: usable,
                        onDrag: { dragRatio = $0 },
                        onCommit: { raw in
                            layout.ratio = PaneLayout.snappedRatio(raw)
                            dragRatio = nil
                        },
                        onStep: { layout.ratio = PaneLayout.steppedRatio(layout.ratio, increment: $0) }
                    )
                    slot(.right, right)
                        .frame(width: usable - leftWidth)
                }
            }
            .background { focusShortcuts(enabled: isSplit) }
        }
    }

    /// ⌘[ and ⌘] move typing between the panes. They are plain buttons, so the
    /// live keyboard (which only claims unmodified keys) doesn't swallow them.
    @ViewBuilder
    private func focusShortcuts(enabled: Bool) -> some View {
        if enabled {
            ZStack {
                Button("Focus Left Pane") { layout.focus(.left) }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Focus Right Pane") { layout.focus(.right) }
                    .keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private func slot(_ slot: PaneLayout.Slot, _ ref: PaneRef) -> some View {
        let isSplit = layout.isSplit
        let isFocused = !isSplit || layout.focused == slot
        return content(ref)
            .environment(\.paneIsFocused, isFocused)
            .environment(\.openPaneMemory, OpenPaneSlot(memory: memory, selection: ref.memoryKey))
            .environment(\.closeDetail, CloseDetailAction(layout: $layout, slot: slot, ref: ref))
            .environment(\.paneSlotActions, PaneSlotActions(
                slot: slot,
                isSplit: isSplit,
                split: { pick(.right) },
                replace: { pick(slot) },
                swap: { layout.swap() },
                fullWidth: { layout.fullWidth(slot) },
                close: { layout.close(slot) },
                focus: { layout.focus(slot) }
            ))
            // Split panes draw their own headers, so keep the shared system bar off
            // even while a pane is still loading and has none.
            .toolbar(isSplit ? .hidden : .automatic, for: .navigationBar)
        .id(ref)
        // Simultaneous, so scrolling and text selection in the pane still work.
        .simultaneousGesture(
            TapGesture().onEnded { layout.focus(slot) },
            including: isSplit && !isFocused ? .all : .none
        )
    }
}

// MARK: - Divider

private struct PaneSplitDivider: View {
    let ratio: Double
    let usableWidth: CGFloat
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    let onStep: (Bool) -> Void

    @State private var startRatio: Double?

    var body: some View {
        ZStack {
            Theme.subtleFill
            Capsule()
                .fill(Theme.textMuted)
                .frame(width: 4, height: 36)
        }
        .frame(width: TwoPaneDetail<EmptyView>.dividerWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startRatio ?? ratio
                    startRatio = start
                    guard usableWidth > 0 else { return }
                    onDrag(min(max(start + value.translation.width / usableWidth, 0.25), 0.75))
                }
                .onEnded { value in
                    let start = startRatio ?? ratio
                    startRatio = nil
                    guard usableWidth > 0 else { return }
                    onCommit(start + value.translation.width / usableWidth)
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Resize panes")
        .accessibilityValue("\(Int((ratio * 100).rounded())) percent left")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(true)
            case .decrement: onStep(false)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("pane-divider")
    }
}

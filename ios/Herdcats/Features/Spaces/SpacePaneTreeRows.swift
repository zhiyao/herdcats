import Observation
import SwiftUI

/// A space whose tree is on screen, and what it was last fetched against.
struct SpacePaneTreeTarget: Hashable {
    let spaceID: String
    let workspaceID: String
    let key: SpacePaneTree.LoadKey
}

/// The tabs and panes fetched for each expanded space.
@Observable
@MainActor
final class SpacePaneTreeStore {
    enum Load {
        case loading
        case loaded(SpacePaneTree.LoadKey, [SpacePaneTab])
        case failed(SpacePaneTree.LoadKey, String)
    }

    private(set) var loads: [String: Load] = [:]
    /// Bumped by Retry so the loading task runs again for the same targets.
    private(set) var retryTick = 0

    func retry(_ spaceID: String) {
        loads[spaceID] = nil
        retryTick += 1
    }

    private func needsLoad(_ target: SpacePaneTreeTarget) -> Bool {
        switch loads[target.spaceID] {
        case nil: true
        case .loading: false
        case let .loaded(key, _): SpacePaneTree.needsReload(loaded: key, current: target.key)
        // A failure waits for Retry, so a flaky host isn't hammered.
        case let .failed(key, _): SpacePaneTree.needsReload(loaded: key, current: target.key)
        }
    }

    /// Fetches the tree for every target that is new or whose counts moved.
    func sync(_ targets: [SpacePaneTreeTarget], connection: HerdrConnection) async {
        for target in targets where needsLoad(target) {
            let previous = loads[target.spaceID]
            // Keep showing the old tree while a refresh runs.
            if case .loaded = previous {} else { loads[target.spaceID] = .loading }
            do {
                async let tabs = connection.tabList(workspaceId: target.workspaceID)
                async let panes = connection.paneList(workspaceId: target.workspaceID)
                let tree = SpacePaneTree.tabs(tabs: try await tabs, panes: try await panes)
                loads[target.spaceID] = .loaded(target.key, tree)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    // Superseded: let the next run start from what was there.
                    loads[target.spaceID] = previous
                    return
                }
                loads[target.spaceID] = .failed(target.key, HerdrConnection.friendlyMessage(for: error))
            }
        }
    }
}

/// The small count pill on a space row that folds or unfolds its tree.
struct SpacePaneTreePill: View {
    let paneCount: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.jost(10, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("\(paneCount)")
                    .font(.jost(12, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide panes" : "Show panes")
        .accessibilityValue("\(paneCount)")
        .accessibilityIdentifier("space-panes-toggle")
    }
}

/// The rows under an expanded space: its tabs as headers, its panes under them.
struct SpacePaneTreeRows: View {
    let space: Space
    let load: SpacePaneTreeStore.Load?
    /// How far the rows sit in from the row above (worktrees are indented already).
    let indent: CGFloat
    @Binding var layout: PaneLayout
    let retry: () -> Void

    var body: some View {
        switch load {
        case nil, .loading:
            HStack(spacing: 8) {
                CircularArcSpinner(size: 11)
                Text("Loading panes…")
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, indent)
            .padding(.vertical, 8)
            .quietListRow()
        case let .failed(_, message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.jost(.footnote))
                    .foregroundStyle(Theme.destructive)
                Button("Retry", action: retry)
                    .font(.jost(.footnote, weight: .semibold))
                    .accessibilityIdentifier("space-panes-retry")
            }
            .padding(.leading, indent)
            .padding(.vertical, 8)
            .quietListRow()
        case let .loaded(_, tabs):
            ForEach(tabs) { tab in
                if tab.showsHeader {
                    Text(tab.headerTitle)
                        .font(.jost(11, weight: .medium))
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, indent)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .quietListRow()
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(tab.panes) { pane in
                    paneRow(pane)
                }
            }
        }
    }

    private func paneRow(_ pane: PaneEntry) -> some View {
        let ref = PaneRef(spaceID: space.id, paneID: pane.paneId)
        let isOpen = layout.left == ref || layout.right == ref
        return Button { layout.openInFocused(ref) } label: {
            PaneTreeRow(pane: pane, indent: indent, isSelected: isOpen)
                .paneSlotBadge(layout.badgeSlot(paneID: pane.paneId), focused: layout.focused)
        }
        .buttonStyle(.plain)
        .paneDraggable(ref, title: pane.displayTitle, enabled: true)
        .contextMenu {
            ForEach(PaneOpenAction.actions(for: ref, layout: $layout)) { action in
                Button(action: action.perform) { Label(action.title, systemImage: action.systemImage) }
            }
        }
        .quietListRow()
        .accessibilityIdentifier("space-pane-row-\(pane.paneId)")
    }
}

private struct PaneTreeRow: View {
    @Environment(\.paneRowBadges) private var paneBadges
    let pane: PaneEntry
    let indent: CGFloat
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: pane.status)
                .frame(width: QuietListMetrics.statusColumn)
            Text(pane.displayTitle)
                .font(.jost(14))
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(paneBadges, id: \.slot) { PaneSlotTag(badge: $0) }
        }
        .padding(.leading, indent)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background { RowHighlight(isActive: false, isSelected: isSelected) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

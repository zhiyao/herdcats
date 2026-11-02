import SwiftUI

// MARK: - Picker rows (pure)

struct PanePickerRow: Identifiable, Equatable {
    let ref: PaneRef
    let title: String
    let status: AgentStatus
    /// The pane already in the target slot.
    let isDisabled: Bool
    /// The pane open in the other slot: choosing it swaps the sides.
    let willSwap: Bool

    var id: PaneRef { ref }
}

struct PanePickerSection: Identifiable, Equatable {
    let spaceID: String
    let title: String
    let rows: [PanePickerRow]

    var id: String { spaceID }
}

enum PanePicker {
    static let wholeSpaceTitle = "Whole space"

    /// One section per space, in list order: the space's default pane, its
    /// agents, then any other panes loaded with "Show all panes…".
    /// A query keeps the rows whose title matches, or every row of a space
    /// whose name matches.
    static func sections(
        spaces: [Space],
        extraPanes: [String: [PaneEntry]],
        layout: PaneLayout,
        slot: PaneLayout.Slot,
        query: String
    ) -> [PanePickerSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func row(_ ref: PaneRef, _ title: String, _ status: AgentStatus) -> PanePickerRow {
            PanePickerRow(
                ref: ref,
                title: title,
                status: status,
                isDisabled: layout.ref(in: slot) == ref,
                willSwap: layout.ref(in: slot.other) == ref
            )
        }

        return spaces.compactMap { space in
            var rows = [row(PaneRef(spaceID: space.id, paneID: nil), wholeSpaceTitle, space.status)]
            rows += space.agents.map {
                row(PaneRef(spaceID: space.id, paneID: $0.paneId), $0.displayTitle, AgentStatus(rawValue: $0.agentStatus) ?? .unknown)
            }
            let agentIDs = Set(space.agents.map(\.paneId))
            rows += (extraPanes[space.id] ?? []).filter { !agentIDs.contains($0.paneId) }.map {
                row(PaneRef(spaceID: space.id, paneID: $0.paneId), $0.displayTitle, $0.status)
            }
            if !needle.isEmpty, !space.label.lowercased().contains(needle) {
                rows = rows.filter { $0.title.lowercased().contains(needle) }
            }
            guard !rows.isEmpty else { return nil }
            return PanePickerSection(spaceID: space.id, title: space.label, rows: rows)
        }
    }

    static func title(slot: PaneLayout.Slot, layout: PaneLayout) -> String {
        guard layout.ref(in: slot) != nil else { return "Open on the Right" }
        return slot == .left ? "Replace Left Pane" : "Replace Right Pane"
    }
}

// MARK: - Picker sheet

/// Chooses the pane for one slot from any space.
struct PanePickerSheet: View {
    let slot: PaneLayout.Slot
    @Binding var layout: PaneLayout

    @Environment(AppModel.self) private var appModel
    @Environment(SpacesModel.self) private var spacesModel: SpacesModel?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Full pane lists loaded on demand, by space id.
    @State private var allPanes: [String: [PaneEntry]] = [:]
    @State private var loading: Set<String> = []

    private var sections: [PanePickerSection] {
        PanePicker.sections(
            spaces: spacesModel?.spaces ?? [],
            extraPanes: allPanes,
            layout: layout,
            slot: slot,
            query: query
        )
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.rows) { row in
                            Button {
                                layout.open(row.ref, in: slot)
                                dismiss()
                            } label: {
                                rowLabel(row)
                            }
                            .disabled(row.isDisabled)
                        }
                        if allPanes[section.spaceID] == nil {
                            Button {
                                Task { await loadAll(spaceID: section.spaceID) }
                            } label: {
                                HStack(spacing: 8) {
                                    Text("Show all panes…")
                                    if loading.contains(section.spaceID) { CircularArcSpinner(size: 12) }
                                }
                                .font(.jost(.footnote))
                            }
                            .disabled(loading.contains(section.spaceID))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.backgroundGradient.ignoresSafeArea())
            .navigationTitle(PanePicker.title(slot: slot, layout: layout))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("pane-picker")
    }

    private func rowLabel(_ row: PanePickerRow) -> some View {
        HStack(spacing: 10) {
            StatusDot(status: row.status)
            Text(row.title)
                .font(.jost(15))
                .lineLimit(1)
            Spacer(minLength: 8)
            if row.willSwap {
                Text("will swap")
                    .font(.jost(11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func loadAll(spaceID: String) async {
        guard let space = spacesModel?.spaces.first(where: { $0.id == spaceID }) else { return }
        loading.insert(spaceID)
        defer { loading.remove(spaceID) }
        let workspaceID = space.workspace.workspaceId
        if let panes = try? await appModel.connection.paneList(workspaceId: workspaceID) {
            allPanes[spaceID] = panes.filter { $0.workspaceId == workspaceID }
        }
    }
}

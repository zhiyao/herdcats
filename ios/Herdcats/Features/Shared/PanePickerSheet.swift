import SwiftUI

// MARK: - Picker rows (pure)

struct PanePickerRow: Identifiable, Equatable {
    let ref: PaneRef
    let title: String
    let status: AgentStatus
    /// The pane already in the target slot.
    let isDisabled: Bool
    /// The pane open in the other slot while the target slot is occupied:
    /// choosing it swaps the sides.
    let willSwap: Bool

    var id: PaneRef { ref }
}

struct PanePickerSection: Identifiable, Equatable {
    let spaceID: String
    let title: String
    let rows: [PanePickerRow]

    var id: String { spaceID }
}

/// The state of one space's "Show all panes…" request.
enum PanePickerLoad: Equatable {
    case loading
    case loaded([PaneEntry])
    case failed(String)

    /// A finished request. A cancelled one (the sheet closed) shows nothing.
    static func resolve(_ result: Result<[PaneEntry], Error>, workspaceID: String) -> PanePickerLoad? {
        switch result {
        case let .success(panes):
            return .loaded(panes.filter { $0.workspaceId == workspaceID })
        case let .failure(error):
            if error is CancellationError { return nil }
            return .failed(HerdrConnection.friendlyMessage(for: error))
        }
    }

    /// The loaded pane lists by space id.
    static func panes(from loads: [String: PanePickerLoad]) -> [String: [PaneEntry]] {
        loads.compactMapValues { if case let .loaded(panes) = $0 { panes } else { nil } }
    }
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
            let target = layout.ref(in: slot)
            let isOpenInOther = layout.ref(in: slot.other) == ref
            return PanePickerRow(
                ref: ref,
                title: title,
                status: status,
                // Already there, or open in the other slot with nothing to swap with.
                isDisabled: target == ref || (target == nil && isOpenInOther),
                willSwap: target != nil && isOpenInOther
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
    var memory: OpenPaneMemory?

    @Environment(AppModel.self) private var appModel
    @Environment(SpacesModel.self) private var spacesModel: SpacesModel?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Full pane lists loaded on demand, by space id.
    @State private var loads: [String: PanePickerLoad] = [:]

    private var sections: [PanePickerSection] {
        PanePicker.sections(
            spaces: spacesModel?.spaces ?? [],
            extraPanes: PanePickerLoad.panes(from: loads),
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
                                layout.open(row.ref, in: slot, shown: OpenPaneMemory.resolver(memory))
                                dismiss()
                            } label: {
                                rowLabel(row)
                            }
                            .disabled(row.isDisabled)
                        }
                        showAllRow(for: section.spaceID)
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

    @ViewBuilder
    private func showAllRow(for spaceID: String) -> some View {
        switch loads[spaceID] {
        case .loaded:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                Text("Show all panes…")
                CircularArcSpinner(size: 12)
            }
            .font(.jost(.footnote))
            .foregroundStyle(.secondary)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.jost(.footnote))
                    .foregroundStyle(Theme.destructive)
                Button("Retry") { Task { await loadAll(spaceID: spaceID) } }
                    .font(.jost(.footnote, weight: .semibold))
                    .accessibilityIdentifier("pane-picker-retry")
            }
        case nil:
            Button("Show all panes…") { Task { await loadAll(spaceID: spaceID) } }
                .font(.jost(.footnote))
        }
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
        let workspaceID = space.workspace.workspaceId
        loads[spaceID] = .loading
        let result: Result<[PaneEntry], Error>
        do {
            result = .success(try await appModel.connection.paneList(workspaceId: workspaceID))
        } catch {
            result = .failure(error)
        }
        loads[spaceID] = PanePickerLoad.resolve(result, workspaceID: workspaceID)
    }
}

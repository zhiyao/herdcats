import Foundation

/// One tab of a space with its panes, for the Spaces list's tree.
struct SpacePaneTab: Identifiable, Equatable {
    let id: String
    let title: String
    let panes: [PaneEntry]
    /// A lone pane in a lone tab needs no header above it.
    let showsHeader: Bool

    var headerTitle: String { "\(title) · \(panes.count)" }
}

/// The pure logic behind the panes and tabs listed under a space's row.
enum SpacePaneTree {
    /// Groups panes under their tab, in tab order. Empty tabs are dropped, and
    /// panes of a tab the list doesn't know still show up.
    static func tabs(tabs: [TabEntry], panes: [PaneEntry]) -> [SpacePaneTab] {
        let byTab = Dictionary(grouping: panes, by: \.tabId)
        var groups = tabs.sorted { $0.number < $1.number }.compactMap { tab -> (String, String, [PaneEntry])? in
            guard let panes = byTab[tab.tabId], !panes.isEmpty else { return nil }
            return (tab.tabId, tab.label, panes)
        }
        let known = Set(tabs.map(\.tabId))
        for tabID in panes.map(\.tabId) where !known.contains(tabID) && !groups.contains(where: { $0.0 == tabID }) {
            groups.append((tabID, "Tab", byTab[tabID] ?? []))
        }
        return groups.map { id, label, panes in
            SpacePaneTab(id: id, title: label, panes: panes, showsHeader: groups.count > 1 || panes.count > 1)
        }
    }

    // MARK: which pane a slot shows

    /// The pane a slot's ref ends up showing. A ref that names no pane opens
    /// the space's remembered sibling, else its focused pane, else the one in
    /// its active tab, else the first, as the detail view resolves it.
    static func shownPaneID(of ref: PaneRef, remembered: String?, panes: [PaneEntry], activeTabID: String) -> String? {
        if let paneID = ref.paneID { return paneID }
        if let remembered, panes.contains(where: { $0.paneId == remembered }) { return remembered }
        return (panes.first(where: \.focused) ?? panes.first { $0.tabId == activeTabID } ?? panes.first)?.paneId
    }

    // MARK: expansion

    /// A space open in a slot unfolds by itself. The user's own choice wins.
    static func isExpanded(_ spaceID: String, overrides: [String: Bool], isOpen: Bool) -> Bool {
        overrides[spaceID] ?? isOpen
    }

    static func toggle(_ spaceID: String, overrides: inout [String: Bool], isOpen: Bool) {
        overrides[spaceID] = !isExpanded(spaceID, overrides: overrides, isOpen: isOpen)
    }

    static func pruned(_ overrides: [String: Bool], keeping spaceIDs: Set<String>) -> [String: Bool] {
        overrides.filter { spaceIDs.contains($0.key) }
    }

    static func encode(_ overrides: [String: Bool]) -> String {
        guard let data = try? JSONEncoder().encode(overrides) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ raw: String) -> [String: Bool] {
        (try? JSONDecoder().decode([String: Bool].self, from: Data(raw.utf8))) ?? [:]
    }

    // MARK: loading

    /// What a loaded tree was fetched against. A space whose counts moved
    /// gained or lost a tab or pane, so its tree is fetched again.
    struct LoadKey: Hashable {
        let tabCount: Int
        let paneCount: Int
    }

    static func needsReload(loaded: LoadKey?, current: LoadKey) -> Bool {
        loaded != current
    }
}

import Testing
@testable import Herdcats

@Suite("Space pane tree")
struct SpacePaneTreeTests {
    private func tab(_ id: String, _ label: String, number: Int) -> TabEntry {
        TabEntry(tabId: id, workspaceId: "w", label: label, number: number, paneCount: 1, agentStatus: "idle", focused: false)
    }

    private func pane(_ id: String, tab: String, title: String = "t") -> PaneEntry {
        PaneEntry(
            paneId: id, tabId: tab, workspaceId: "w", label: nil, agent: nil, agentStatus: "idle",
            cwd: nil, terminalTitle: title, terminalTitleStripped: title, focused: false, revision: nil
        )
    }

    // MARK: tabs

    @Test func panesGroupUnderTheirTabInTabOrder() {
        let tabs = [tab("t2", "tests", number: 2), tab("t1", "main", number: 1)]
        let panes = [pane("p1", tab: "t1"), pane("p2", tab: "t2"), pane("p3", tab: "t1")]
        let result = SpacePaneTree.tabs(tabs: tabs, panes: panes)
        #expect(result.map(\.id) == ["t1", "t2"])
        #expect(result[0].panes.map(\.paneId) == ["p1", "p3"])
        #expect(result[1].panes.map(\.paneId) == ["p2"])
    }

    @Test func emptyTabsAreDropped() {
        let result = SpacePaneTree.tabs(
            tabs: [tab("t1", "main", number: 1), tab("t2", "empty", number: 2)],
            panes: [pane("p1", tab: "t1")]
        )
        #expect(result.map(\.id) == ["t1"])
    }

    @Test func panesOfAnUnlistedTabStillAppear() {
        let result = SpacePaneTree.tabs(tabs: [], panes: [pane("p1", tab: "gone")])
        #expect(result.count == 1)
        #expect(result[0].panes.map(\.paneId) == ["p1"])
    }

    // MARK: expansion

    @Test func openSpacesUnfoldByDefault() {
        #expect(SpacePaneTree.isExpanded("w1", overrides: [:], isOpen: true))
        #expect(!SpacePaneTree.isExpanded("w1", overrides: [:], isOpen: false))
    }

    @Test func anOverrideBeatsTheDefault() {
        #expect(!SpacePaneTree.isExpanded("w1", overrides: ["w1": false], isOpen: true))
        #expect(SpacePaneTree.isExpanded("w1", overrides: ["w1": true], isOpen: false))
    }

    @Test func togglingStoresTheOppositeOfWhatShows() {
        var overrides: [String: Bool] = [:]
        SpacePaneTree.toggle("w1", overrides: &overrides, isOpen: true)
        #expect(overrides["w1"] == false)
        SpacePaneTree.toggle("w1", overrides: &overrides, isOpen: true)
        #expect(overrides["w1"] == true)
    }

    @Test func overridesRoundTripThroughStorage() {
        let overrides = ["w1": true, "w2": false]
        #expect(SpacePaneTree.decode(SpacePaneTree.encode(overrides)) == overrides)
        #expect(SpacePaneTree.decode("").isEmpty)
        #expect(SpacePaneTree.decode("garbage").isEmpty)
    }

    @Test func pruningDropsOverridesForSpacesThatAreGone() {
        let kept = SpacePaneTree.pruned(["w1": true, "w2": false], keeping: ["w1"])
        #expect(kept == ["w1": true])
    }

    // MARK: loading

    @Test func aLoadIsStaleOnlyWhenTheSpacesCountsMoved() {
        let key = SpacePaneTree.LoadKey(tabCount: 2, paneCount: 3)
        #expect(!SpacePaneTree.needsReload(loaded: key, current: key))
        #expect(SpacePaneTree.needsReload(loaded: key, current: .init(tabCount: 2, paneCount: 4)))
        #expect(SpacePaneTree.needsReload(loaded: nil, current: key))
    }

    // MARK: which pane a slot shows

    private func pane(_ id: String, tab: String, focused: Bool) -> PaneEntry {
        PaneEntry(
            paneId: id, tabId: tab, workspaceId: "w", label: nil, agent: nil, agentStatus: "idle",
            cwd: nil, terminalTitle: "t", terminalTitleStripped: "t", focused: focused, revision: nil
        )
    }

    @Test func aPaneRefShowsItsOwnPane() {
        let shown = SpacePaneTree.shownPaneID(
            of: PaneRef(spaceID: "w", paneID: "p2"), remembered: "p1",
            panes: [pane("p1", tab: "t1", focused: true)], activeTabID: "t1"
        )
        #expect(shown == "p2")
    }

    @Test func aSpaceRefShowsTheRememberedSiblingWhenItStillExists() {
        let panes = [pane("p1", tab: "t1", focused: true), pane("p2", tab: "t1", focused: false)]
        let ref = PaneRef(spaceID: "w", paneID: nil)
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: "p2", panes: panes, activeTabID: "t1") == "p2")
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: "gone", panes: panes, activeTabID: "t1") == "p1")
    }

    @Test func aSpaceRefFallsBackToFocusedThenActiveTabThenFirst() {
        let ref = PaneRef(spaceID: "w", paneID: nil)
        let focused = [pane("p1", tab: "t1", focused: false), pane("p2", tab: "t2", focused: true)]
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: nil, panes: focused, activeTabID: "t1") == "p2")
        let none = [pane("p1", tab: "t1", focused: false), pane("p2", tab: "t2", focused: false)]
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: nil, panes: none, activeTabID: "t2") == "p2")
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: nil, panes: none, activeTabID: "zz") == "p1")
        #expect(SpacePaneTree.shownPaneID(of: ref, remembered: nil, panes: [], activeTabID: "t1") == nil)
    }
}

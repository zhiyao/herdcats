import Testing
@testable import Herdcats

@Suite("Pane picker")
struct PanePickerTests {
    private func agent(_ id: String, title: String? = nil, status: String = "working", workspace: String) -> AgentEntry {
        AgentEntry(
            agent: "codex", agentStatus: status, stateChangeSeq: nil, cwd: nil,
            paneId: id, tabId: "t", workspaceId: workspace,
            terminalTitle: title, terminalTitleStripped: title, focused: false, revision: nil
        )
    }

    private func pane(_ id: String, title: String, workspace: String) -> PaneEntry {
        PaneEntry(
            paneId: id, tabId: "t", workspaceId: workspace, label: nil, agent: nil, agentStatus: "unknown",
            cwd: nil, terminalTitle: title, terminalTitleStripped: title, focused: false, revision: nil
        )
    }

    private func space(_ id: String, _ label: String, agents: [AgentEntry] = []) -> Space {
        Space(
            workspace: Workspace(
                workspaceId: id, label: label, number: 1, tabCount: 1, paneCount: 1,
                activeTabId: "t", agentStatus: "idle", focused: false, worktree: nil
            ),
            agents: agents
        )
    }

    private var spaces: [Space] {
        [
            space("w1", "Alpha", agents: [agent("p1", title: "Fix build", workspace: "w1")]),
            space("w2", "Beta", agents: [agent("p2", title: "Write docs", workspace: "w2")]),
        ]
    }

    private func sections(
        layout: PaneLayout = PaneLayout(),
        slot: PaneLayout.Slot = .right,
        extra: [String: [PaneEntry]] = [:],
        query: String = ""
    ) -> [PanePickerSection] {
        PanePicker.sections(spaces: spaces, extraPanes: extra, layout: layout, slot: slot, query: query)
    }

    @Test func eachSpaceStartsWithItsWholeSpaceRowThenItsAgents() {
        let result = sections()
        #expect(result.map(\.spaceID) == ["w1", "w2"])
        #expect(result[0].rows.map(\.ref) == [
            PaneRef(spaceID: "w1", paneID: nil),
            PaneRef(spaceID: "w1", paneID: "p1"),
        ])
        #expect(result[0].rows.map(\.title) == ["Whole space", "Fix build"])
    }

    @Test func thePaneInTheTargetSlotIsDisabled() {
        let layout = PaneLayout(left: PaneRef(spaceID: "w1", paneID: "p1"))
        let rows = sections(layout: layout, slot: .left).flatMap(\.rows)
        #expect(rows.first { $0.ref == PaneRef(spaceID: "w1", paneID: "p1") }?.isDisabled == true)
        #expect(rows.filter(\.isDisabled).count == 1)
    }

    @Test func thePaneInTheOtherSlotWillSwap() {
        var layout = PaneLayout(left: PaneRef(spaceID: "w1", paneID: "p1"))
        layout.open(PaneRef(spaceID: "w2", paneID: "p2"), in: .right)
        let rows = sections(layout: layout, slot: .right).flatMap(\.rows)
        let leftRow = rows.first { $0.ref == PaneRef(spaceID: "w1", paneID: "p1") }
        #expect(leftRow?.willSwap == true)
        #expect(leftRow?.isDisabled == false)
        #expect(rows.filter(\.willSwap).count == 1)
    }

    @Test func aPaneAlreadyOpenIsNotOfferedAsASwapWhenTheTargetSlotIsEmpty() {
        let layout = PaneLayout(left: PaneRef(spaceID: "w1", paneID: "p1"))
        let row = sections(layout: layout, slot: .right).flatMap(\.rows)
            .first { $0.ref == PaneRef(spaceID: "w1", paneID: "p1") }
        #expect(row?.willSwap == false)
        #expect(row?.isDisabled == true)
    }

    @Test func showAllPanesAddsShellsWithoutDuplicatingAgents() {
        let extra = ["w1": [
            pane("p1", title: "Fix build", workspace: "w1"),
            pane("s1", title: "zsh", workspace: "w1"),
        ]]
        let rows = sections(extra: extra)[0].rows
        #expect(rows.map(\.ref.paneID) == [nil, "p1", "s1"])
        #expect(rows.last?.title == "zsh")
    }

    @Test func searchMatchesPaneTitlesAndKeepsOnlyMatchingRows() {
        let result = sections(query: "docs")
        #expect(result.map(\.spaceID) == ["w2"])
        #expect(result[0].rows.map(\.title) == ["Write docs"])
    }

    @Test func searchMatchingASpaceNameKeepsAllItsRows() {
        let result = sections(query: "alp")
        #expect(result.map(\.spaceID) == ["w1"])
        #expect(result[0].rows.count == 2)
    }

    @Test func searchIgnoresCaseAndSurroundingSpacesAndDropsEmptySections() {
        #expect(sections(query: "  FIX ").map(\.spaceID) == ["w1"])
        #expect(sections(query: "zzz").isEmpty)
    }

    // MARK: Row badges

    @Test func badgesOnlyShowWhileSplit() {
        let single = PaneLayout(left: PaneRef(spaceID: "w1", paneID: nil))
        #expect(single.badgeSlots(spaceID: "w1").isEmpty)
        let both = PaneLayout(left: PaneRef(spaceID: "w1", paneID: nil), right: PaneRef(spaceID: "w2", paneID: "p2"))
        #expect(both.badgeSlots(spaceID: "w1") == [.left])
        #expect(both.badgeSlots(spaceID: "w2") == [.right])
        #expect(both.badgeSlots(spaceID: "w3").isEmpty)
    }

    @Test func aSpaceOpenInBothSlotsShowsBothBadges() {
        let both = PaneLayout(left: PaneRef(spaceID: "w1", paneID: "p1"), right: PaneRef(spaceID: "w1", paneID: "p2"))
        #expect(both.badgeSlots(spaceID: "w1") == [.left, .right])
    }

    @Test func agentBadgesMatchOnPaneID() {
        let both = PaneLayout(left: PaneRef(spaceID: "w1", paneID: "p1"), right: PaneRef(spaceID: "w2", paneID: "p2"))
        #expect(both.badgeSlot(paneID: "p1") == .left)
        #expect(both.badgeSlot(paneID: "p2") == .right)
        #expect(both.badgeSlot(paneID: "p9") == nil)
    }

    // MARK: Show all panes

    @Test func loadedPanesAreFilteredToTheirWorkspace() {
        let result = PanePickerLoad.resolve(
            .success([pane("a", title: "A", workspace: "w1"), pane("b", title: "B", workspace: "w2")]),
            workspaceID: "w1"
        )
        #expect(result == .loaded([pane("a", title: "A", workspace: "w1")]))
    }

    @Test func aFailedLoadCarriesTheFriendlyMessage() {
        let error = HerdrError.unexpectedResponse("quota-axi returned empty output")
        #expect(
            PanePickerLoad.resolve(.failure(error), workspaceID: "w1")
                == .failed(HerdrConnection.friendlyMessage(for: error))
        )
    }

    @Test func aCancelledLoadShowsNothing() {
        #expect(PanePickerLoad.resolve(.failure(CancellationError()), workspaceID: "w1") == nil)
    }

    @Test func onlyLoadedPanesFeedTheSections() {
        let loads: [String: PanePickerLoad] = [
            "w1": .loaded([pane("s1", title: "zsh", workspace: "w1")]),
            "w2": .failed("offline"),
        ]
        #expect(PanePickerLoad.panes(from: loads).keys.sorted() == ["w1"])
    }
}

import Foundation
import Testing
@testable import Herdcats

@Suite("Agent list presentation")
struct AgentListPresentationTests {
    private func agent(
        paneId: String = "w1:p1",
        terminal: String? = "π - firstmate",
        name: String? = nil,
        workspaceLabel: String? = nil,
        tabLabel: String? = nil,
        cwd: String? = "/Users/demo/1/firstmate",
        status: String = "working"
    ) -> AgentEntry {
        AgentEntry(
            agent: "pi", agentStatus: status, stateChangeSeq: 10,
            cwd: cwd, paneId: paneId, tabId: "t1", workspaceId: "w1",
            terminalTitle: terminal, terminalTitleStripped: terminal,
            focused: false, revision: 1,
            name: name, workspaceLabel: workspaceLabel, tabLabel: tabLabel
        )
    }

    private func workspace(label: String) -> Workspace {
        Workspace(
            workspaceId: "w1", label: label, number: 1, tabCount: 1, paneCount: 1,
            activeTabId: "t1", agentStatus: "working", focused: false, worktree: nil
        )
    }

    @Test
    func decodesWorkspaceTabAndAgentNameFields() throws {
        let json = """
        {"id":"cli:agent:list","result":{"type":"agent_list","agents":[
        {"agent":"cursor","agent_status":"idle","cwd":"/Users/demo/Projects/herdcats","focused":false,
        "name":"iap-impl","pane_id":"w9:p1","revision":3,"state_change_seq":9,
        "tab_id":"w9:t1","tab_label":"fm-tingxiemao","terminal_id":"term_1",
        "terminal_title":"cursor-agent --resume a0291794","terminal_title_stripped":"cursor-agent --resume a0291794",
        "workspace_id":"w9","workspace_label":"2ndmate-tingxiemao"}
        ]}}
        """
        let entry = try #require(HerdrConnection.decode(json, as: AgentListResult.self).agents.first)
        #expect(entry.name == "iap-impl")
        #expect(entry.workspaceLabel == "2ndmate-tingxiemao")
        #expect(entry.tabLabel == "fm-tingxiemao")
        #expect(entry.terminalTitleStripped == "cursor-agent --resume a0291794")
    }

    @Test
    func toleratesNilAndEmptyNameFields() throws {
        let json = """
        {"id":"cli:agent:list","result":{"type":"agent_list","agents":[
        {"agent":"pi","agent_status":"working","focused":true,"name":null,"pane_id":"w1:p1",
        "revision":1,"state_change_seq":1,"tab_id":"t1","tab_label":"","terminal_id":"term_1",
        "terminal_title":"π - firstmate","terminal_title_stripped":"π - firstmate",
        "workspace_id":"w1","workspace_label":"  "}
        ]}}
        """
        let entry = try #require(HerdrConnection.decode(json, as: AgentListResult.self).agents.first)
        #expect(entry.name == nil)
        #expect(entry.workspaceLabel == "  ")
        #expect(entry.tabLabel == "")
        #expect(AgentListPresentation.title(agent: entry, workspaceLabel: nil) == "π - firstmate")
    }

    @Test
    func prefersWorkspaceThenTabThenAgentNameThenTerminal() {
        let collision = agent(terminal: "π - firstmate")
        #expect(AgentListPresentation.title(agent: collision, workspaceLabel: "firstmate") == "firstmate")
        #expect(AgentListPresentation.title(
            agent: agent(
                terminal: "π - firstmate",
                workspaceLabel: "2ndmate-tingxiemao",
                tabLabel: "fm-tingxiemao"
            ),
            workspaceLabel: nil
        ) == "2ndmate-tingxiemao")
        #expect(AgentListPresentation.title(
            agent: agent(
                terminal: "π - firstmate",
                name: "ignored-when-tab-present",
                tabLabel: "fm-herdrcat"
            ),
            workspaceLabel: nil
        ) == "fm-herdrcat")
        #expect(AgentListPresentation.title(
            agent: agent(terminal: "cursor-agent --resume a0291794", name: "iap-impl"),
            workspaceLabel: ""
        ) == "iap-impl")
        #expect(AgentListPresentation.title(
            agent: agent(terminal: "π - firstmate"),
            workspaceLabel: nil
        ) == "π - firstmate")
        #expect(AgentListPresentation.title(
            agent: agent(terminal: nil, cwd: nil),
            workspaceLabel: "   "
        ) == "w1:p1")
    }

    @Test
    func collisionFixtureYieldsDistinctWorkspaceTitles() throws {
        let fixture = """
        {"id":"cli:agent:list","result":{"type":"agent_list","agents":[
        {"agent":"pi","agent_status":"working","cwd":"/Users/demo/1/firstmate","focused":true,
        "pane_id":"p0","revision":1,"state_change_seq":10,"tab_id":"t0","tab_label":"1",
        "terminal_title":"π - firstmate","terminal_title_stripped":"π - firstmate",
        "workspace_id":"w0","workspace_label":"firstmate"},
        {"agent":"pi","agent_status":"working","cwd":"/Users/demo/Projects/firstmate","focused":false,
        "pane_id":"p1","revision":1,"state_change_seq":9,"tab_id":"t1","tab_label":"fm-tingxiemao",
        "terminal_title":"π - firstmate","terminal_title_stripped":"π - firstmate",
        "workspace_id":"w1","workspace_label":"2ndmate-tingxiemao"},
        {"agent":"pi","agent_status":"blocked","cwd":"/Users/demo/2/firstmate","focused":false,
        "pane_id":"p2","revision":1,"state_change_seq":8,"tab_id":"t2","tab_label":"fm-herdrcat",
        "terminal_title":"π - firstmate","terminal_title_stripped":"π - firstmate",
        "workspace_id":"w2","workspace_label":"2ndmate-herdrcat"}
        ]}}
        """
        let agents = try HerdrConnection.decode(fixture, as: AgentListResult.self).agents
        let titles = agents.map {
            AgentListPresentation.title(agent: $0, workspaceLabel: nil)
        }
        #expect(titles == ["firstmate", "2ndmate-tingxiemao", "2ndmate-herdrcat"])
        #expect(Set(titles).count == 3)
        #expect(agents.map(\.agentStatus) == ["working", "working", "blocked"])
        #expect(agents.map(\.displayTitle) == Array(repeating: "π - firstmate", count: 3))
    }

    @Test
    func subtitleShowsMachineWorkspaceContextForNamedRows() {
        let named = agent(
            terminal: "π - firstmate",
            workspaceLabel: "2ndmate-tingxiemao",
            tabLabel: "fm-tingxiemao"
        )
        let title = AgentListPresentation.title(agent: named, workspaceLabel: nil)
        #expect(title == "2ndmate-tingxiemao")
        #expect(
            AgentListPresentation.subtitle(
                agent: named, workspaceLabel: nil, machineName: "studio-mac", title: title
            ) == "studio-mac"
        )

        let byTab = agent(terminal: "π - firstmate", tabLabel: "fm-herdrcat")
        let tabTitle = AgentListPresentation.title(agent: byTab, workspaceLabel: "2ndmate-herdrcat")
        #expect(tabTitle == "2ndmate-herdrcat")
        #expect(
            AgentListPresentation.subtitle(
                agent: byTab, workspaceLabel: "2ndmate-herdrcat",
                machineName: "studio-mac", title: tabTitle
            ) == "studio-mac"
        )

        let byName = agent(terminal: "cursor-agent --resume x", name: "iap-impl")
        let nameTitle = AgentListPresentation.title(agent: byName, workspaceLabel: nil)
        #expect(
            AgentListPresentation.subtitle(
                agent: byName, workspaceLabel: nil, machineName: "studio-mac", title: nameTitle
            ) == "studio-mac"
        )
    }

    @Test
    func subtitleFallsBackToCwdForTerminalTitles() {
        let terminalOnly = agent(
            terminal: "π - firstmate",
            name: nil,
            workspaceLabel: nil,
            tabLabel: nil
        )
        let title = AgentListPresentation.title(agent: terminalOnly, workspaceLabel: nil)
        #expect(title == "π - firstmate")
        #expect(
            AgentListPresentation.subtitle(
                agent: terminalOnly, workspaceLabel: nil, machineName: "studio-mac", title: title
            ) == "~/1/firstmate"
        )
    }

    @Test
    func agentListItemUsesJoinedWorkspaceLabelWhenAgentOmitsIt() {
        let entry = agent(terminal: "π - firstmate", workspaceLabel: nil)
        let item = AgentListItem(
            space: Space(workspace: workspace(label: "firstmate"), agents: [entry]),
            agent: entry
        )
        #expect(item.title == "firstmate")
        #expect(item.subtitle(machineName: "studio-mac") == "studio-mac")
    }
}

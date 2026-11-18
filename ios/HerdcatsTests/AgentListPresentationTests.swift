import Foundation
import Testing
@testable import Herdcats

@Suite("Agent list presentation")
struct AgentListPresentationTests {
    private func workspace(_ label: String) -> Workspace {
        Workspace(
            workspaceId: "w1", label: label, number: 1, tabCount: 1, paneCount: 1,
            activeTabId: "t1", agentStatus: "working", focused: true, worktree: nil
        )
    }

    private func decodeAgent(name: String) throws -> AgentEntry {
        let json = """
        {"result":{"agents":[
        {"agent":"pi","agent_status":"working","cwd":"/Users/demo/1/firstmate","focused":true,
        "name":\(name),"pane_id":"p1","revision":1,"state_change_seq":10,"tab_id":"t1",
        "terminal_title":"π · firstmate","terminal_title_stripped":"π · firstmate","workspace_id":"w1"}
        ]}}
        """
        return try #require(HerdrConnection.decode(json, as: AgentListResult.self).agents.first)
    }

    @Test
    func tuiWorkspaceAndMatchingTabTakePriorityOverAgentName() throws {
        let entry = try decodeAgent(name: #""iap-impl""#)
        let tabs = try HerdrConnection.decode("""
        {"result":{"tabs":[
        {"tab_id":"t1","workspace_id":"w2","label":"Other workspace","number":1,
         "pane_count":1,"agent_status":"working","focused":true},
        {"tab_id":"t1","workspace_id":"w1","label":" fm-tingxiemao ","number":2,
         "pane_count":1,"agent_status":"working","focused":true}
        ]}}
        """, as: TabListResult.self).tabs

        let named = entry.withTUIListNames(workspace: workspace("firstmate"), tabs: tabs)
        let space = try #require(Space.join(workspaces: [workspace("firstmate")], agents: [named]).first)
        let item = AgentListItem(space: space, agent: try #require(space.agents.first))
        #expect(item.title == "firstmate")
        #expect(item.presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac")
        #expect(item.agent.displayTitle == "π · firstmate")
        #expect(item.agent.stateChangeSeq == 10)
        #expect(item.status == .working)

        let tab = entry.withTUIListNames(workspace: workspace(" \n "), tabs: tabs)
        #expect(AgentListPresentation(agent: tab).title == "fm-tingxiemao")

        let agent = entry.withTUIListNames(workspace: workspace(""), tabs: Array(tabs.prefix(1)))
        #expect(AgentListPresentation(agent: agent).title == "iap-impl")
    }

    @Test(arguments: ["null", #""   ""#])
    func tuiMissingNamesUseTerminalTitleAndKeepMachineContext(name: String) throws {
        let entry = try decodeAgent(name: name)
        let blankTab = TabEntry(
            tabId: "t1", workspaceId: "w1", label: " ", number: 1,
            paneCount: 1, agentStatus: "working", focused: false
        )
        let fallback = entry.withTUIListNames(workspace: workspace(" "), tabs: [blankTab])
        let presentation = AgentListPresentation(agent: fallback)
        #expect(presentation.title == "π · firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · ~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.text == "~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.isPath == true)
    }

    @Test
    func coreUsesLayoutNamesAndKeepsStandaloneTerminalTitles() throws {
        let snapshot = try CoreSnapshot(subscription: JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"seq":1,"terminals":[
          {"address":"studio/t1","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/t2","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/t3","title":"First terminal","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"t4","title":"Second terminal","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"t5","name":"iap-impl","title":"Third terminal","state":"live","status":{"app":"pi","state":"working"}}
        ]}
        """.utf8)))
        let layout = try JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"spaces":[
          {"id":"w1","name":"firstmate","tabs":[
            {"id":"t1","name":"Main","root":{"content":{"terminal":"t1"}}}
          ]},
          {"id":"w2","name":" ","folder":"/work/firstmate","tabs":[
            {"id":"t2","name":"2ndmate-tingxiemao","root":{"content":{"terminal":"t2"}}}
          ]}
        ]}
        """.utf8))
        let hierarchy = snapshot.presentation(layout: nil, remoteLayouts: ["studio": layout])
        let spaces = Space.join(workspaces: hierarchy.workspaces, agents: hierarchy.agents)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)

        #expect(items.first { $0.id == "studio/t1" }?.title == "firstmate")
        #expect(items.first { $0.id == "studio/t2" }?.title == "2ndmate-tingxiemao")
        #expect(items.first { $0.id == "studio/t3" }?.title == "First terminal")
        #expect(items.first { $0.id == "t4" }?.title == "Second terminal")
        #expect(items.first { $0.id == "t5" }?.title == "iap-impl")
        for id in ["studio/t1", "studio/t2", "studio/t3"] {
            let item = try #require(items.first { $0.id == id })
            #expect(item.presentation.subtitle(connectionHost: "gateway")?.text == "studio")
        }
    }
}

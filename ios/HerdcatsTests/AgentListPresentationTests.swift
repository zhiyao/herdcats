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

    private func decodeAgent(
        name: String, paneID: String = "p1", terminal: String = "π · firstmate"
    ) throws -> AgentEntry {
        let json = """
        {"result":{"agents":[
        {"agent":"pi","agent_status":"working","cwd":"/Users/demo/1/firstmate","focused":true,
        "name":\(name),"pane_id":"\(paneID)","revision":1,"state_change_seq":10,"tab_id":"t1",
        "terminal_title":"\(terminal)","terminal_title_stripped":"\(terminal)","workspace_id":"w1"}
        ]}}
        """
        return try #require(HerdrConnection.decode(json, as: AgentListResult.self).agents.first)
    }

    @Test(arguments: [" fm-tingxiemao ", "1"])
    func tuiWorkspaceAndMatchingTabTakePriorityOverAgentName(tabLabel: String) throws {
        let entry = try decodeAgent(name: #""iap-impl""#)
        let tabs = try HerdrConnection.decode("""
        {"result":{"tabs":[
        {"tab_id":"t1","workspace_id":"w2","label":"Other workspace","number":1,
         "pane_count":1,"agent_status":"working","focused":true},
        {"tab_id":"t1","workspace_id":"w1","label":"\(tabLabel)","number":2,
         "pane_count":1,"agent_status":"working","focused":true}
        ]}}
        """, as: TabListResult.self).tabs

        let named = entry.withTUIListNames(workspace: workspace("firstmate"), tabs: tabs)
        let space = try #require(Space.join(workspaces: [workspace("firstmate")], agents: [named]).first)
        let item = AgentListItem(space: space, agent: try #require(space.agents.first))
        #expect(item.title == "firstmate")
        #expect(item.presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · π · firstmate")
        #expect(item.agent.displayTitle == "π · firstmate")
        #expect(item.agent.stateChangeSeq == 10)
        #expect(item.status == .working)

        let tab = entry.withTUIListNames(workspace: workspace(" \n "), tabs: tabs)
        #expect(AgentListPresentation(agent: tab).title == tabLabel)

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
    func workspaceFirstRowsKeepDistinctTerminalContext() throws {
        let example = workspace("ExampleApp")
        let entries = [
            try decodeAgent(name: "null", paneID: "p1", terminal: "App Store Text"),
            try decodeAgent(name: "null", paneID: "p2", terminal: "Sharing with Android")
        ].map { $0.withTUIListNames(workspace: example, tabs: []) }
        let spaces = Space.join(workspaces: [example], agents: entries)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)

        #expect(items.map(\.title) == ["ExampleApp", "ExampleApp"])
        #expect(items.compactMap { $0.presentation.subtitle(connectionHost: "studio-mac")?.text }
            == ["studio-mac · App Store Text", "studio-mac · Sharing with Android"])
        #expect(items.map { $0.presentation.dragTitle }
            == ["ExampleApp · App Store Text", "ExampleApp · Sharing with Android"])
    }

    @Test
    func matchingTerminalTitlesUseDistinctTabNameAgentNameOrDirectory() throws {
        let example = workspace("ExampleApp")
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/review","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/work/review","pane_id":"b","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate","name":"Build App"},
          {"agent":"pi","agent_status":"working","cwd":"/one/project/app","pane_id":"c","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/two/project/app","pane_id":"d","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/work/docs","pane_id":"e","tab_id":"t2","workspace_id":"w1","focused":false}
        ]}}
        """
        let tabs = [
            TabEntry(tabId: "t1", workspaceId: "w1", label: "Review", number: 1,
                     paneCount: 1, agentStatus: "working", focused: false),
            TabEntry(tabId: "t2", workspaceId: "w1", label: "Build", number: 2,
                     paneCount: 4, agentStatus: "working", focused: false)
        ]
        let entries = try HerdrConnection.decode(rows, as: AgentListResult.self).agents
            .map { $0.withTUIListNames(workspace: example, tabs: tabs) }
        let items = AgentListItem.grouped(in: Space.join(workspaces: [example], agents: entries))
            .flatMap(\.items).sorted { $0.id < $1.id }
        let context = ["Review", "Build App", "/one/project/app", "/two/project/app", "~/work/docs"]
        #expect(items.map(\.title) == Array(repeating: "ExampleApp", count: 5))
        #expect(items.compactMap { $0.presentation.subtitle(connectionHost: "studio")?.text }
            == context.map { "studio · \($0)" })
        #expect(items.map { $0.presentation.dragTitle }
            == context.map { "ExampleApp · \($0)" })
    }

    @Test
    func priorityTiesUseTerminalTitles() throws {
        let example = workspace("ExampleApp")
        let entries = [
            try decodeAgent(name: "null", paneID: "p1", terminal: "Zulu"),
            try decodeAgent(name: "null", paneID: "p2", terminal: "Alpha")
        ].map { $0.withTUIListNames(workspace: example, tabs: []) }
        let space = Space(workspace: example, agents: entries)
        let items = entries.map { AgentListItem(space: space, agent: $0) }
        #expect(items.sorted(by: AgentListItem.attentionOrder).map(\.id) == ["p2", "p1"])
    }

    @Test
    func coreUsesLayoutNamesAndKeepsStandaloneTerminalTitles() throws {
        let snapshot = try CoreSnapshot(subscription: JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"seq":1,"terminals":[
          {"address":"studio/t1","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/peer/t2","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/peer/t3","title":"First terminal","state":"live","status":{"app":"pi","state":"working"}},
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
            {"id":"t2","name":"2ndmate-tingxiemao","root":{"content":{"terminal":"peer/t2"}}}
          ]}
        ]}
        """.utf8))
        let hierarchy = snapshot.presentation(layout: nil, remoteLayouts: ["studio": layout])
        let spaces = Space.join(workspaces: hierarchy.workspaces, agents: hierarchy.agents)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)

        #expect(items.first { $0.id == "studio/t1" }?.title == "firstmate")
        #expect(items.first { $0.id == "studio/peer/t2" }?.title == "2ndmate-tingxiemao")
        #expect(items.first { $0.id == "studio/peer/t3" }?.title == "First terminal")
        #expect(items.first { $0.id == "t4" }?.title == "Second terminal")
        #expect(items.first { $0.id == "t5" }?.title == "iap-impl")
        let subtitles = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.presentation.subtitle(connectionHost: "gateway").map { (item.id, $0.text) }
        })
        #expect(subtitles["studio/t1"] == "studio · π · firstmate")
        #expect(subtitles["studio/peer/t2"] == "peer · π · firstmate")
        #expect(subtitles["studio/peer/t3"] == "peer")
        #expect(subtitles["t4"] == "gateway")
    }
}

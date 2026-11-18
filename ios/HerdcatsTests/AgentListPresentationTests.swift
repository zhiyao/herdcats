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
        name: String, paneID: String = "p1", terminal: String = "π · firstmate", tab: String? = nil
    ) throws -> AgentEntry {
        let json = """
        {"result":{"agents":[
        {"agent":"pi","agent_status":"working","cwd":"/Users/demo/1/firstmate","focused":true,
        "name":\(name),"tab_label":\(tab.map { "\"\($0)\"" } ?? "null"),"pane_id":"\(paneID)","revision":1,"state_change_seq":10,"tab_id":"t1",
        "terminal_title":"\(terminal)","terminal_title_stripped":"\(terminal)","workspace_id":"w1"}
        ]}}
        """
        return try #require(HerdrConnection.decode(json, as: AgentListResult.self).agents.first)
    }

    @Test(arguments: [" fm-tingxiemao ", "1"])
    func tuiWorkspaceAndMatchingTabTakePriorityOverAgentName(tabLabel: String) throws {
        var entry = try decodeAgent(name: #""iap-impl""#, tab: tabLabel)
        #expect(AgentListPresentation(agent: entry).title == tabLabel)
        entry.workspaceLabel = "firstmate"
        let presentation = AgentListPresentation(agent: entry)
        #expect(presentation.title == "firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · ~/1/firstmate")
        #expect(entry.displayTitle == "π · firstmate")
        #expect(entry.stateChangeSeq == 10)
        #expect(entry.agentStatus == "working")

        let agent = try decodeAgent(name: #""iap-impl""#)
        #expect(AgentListPresentation(agent: agent).title == "iap-impl")
    }

    @Test(arguments: ["null", #""   ""#])
    func tuiMissingNamesUseTerminalTitleAndKeepMachineContext(name: String) throws {
        let entry = try decodeAgent(name: name, tab: " ")
        let presentation = AgentListPresentation(agent: entry)
        #expect(presentation.title == "π · firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · ~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.text == "~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.isPath == true)
    }

    @Test
    func overviewUsesForegroundDirectoryAndFallsBackToLaunchDirectory() throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/launch","foreground_cwd":"/work/review","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"},
          {"agent":"pi","agent_status":"working","cwd":"/work/launch","foreground_cwd":"/work/checkout","pane_id":"b","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"},
          {"agent":"pi","agent_status":"working","cwd":"/work/launch","foreground_cwd":" ","pane_id":"c","tab_id":"t3","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"}
        ]}}
        """
        let entries = try HerdrConnection.decode(rows, as: AgentListResult.self).agents.map { entry in
            var entry = entry
            entry.workspaceLabel = "ExampleApp"
            return entry
        }
        let presentations = entries.map { AgentListPresentation(agent: $0, peers: entries) }
        #expect(presentations.map(\.title) == ["ExampleApp", "ExampleApp", "ExampleApp"])
        #expect(presentations.compactMap { $0.subtitle(connectionHost: "studio")?.text } == [
            "studio · ~/work/review",
            "studio · ~/work/checkout",
            "studio · ~/work/launch"
        ])
        #expect(entries.map(\.shortCwd) == Array(repeating: "~/work/launch", count: 3))
    }

    @Test
    func workspaceFirstRowsKeepDistinctTerminalContext() throws {
        let example = workspace("ExampleApp")
        let entries = [
            try decodeAgent(name: "null", paneID: "p1", terminal: "App Store Text"),
            try decodeAgent(name: "null", paneID: "p2", terminal: "Sharing with Android")
        ].map { entry in
            var entry = entry
            entry.workspaceLabel = example.label
            return entry
        }
        let spaces = Space.join(workspaces: [example], agents: entries)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)

        #expect(items.map { AgentListPresentation(agent: $0.agent, peers: entries).title } == ["ExampleApp", "ExampleApp"])
        #expect(items.compactMap { AgentListPresentation(agent: $0.agent, peers: entries).subtitle(connectionHost: "studio-mac")?.text }
            == ["studio-mac · App Store Text", "studio-mac · Sharing with Android"])
    }

    @Test
    func matchingTerminalTitlesUseDistinctTabNameAgentNameOrDirectory() throws {
        let example = workspace("ExampleApp")
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/review","pane_id":"a","tab_label":"Review","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/work/review","pane_id":"b","tab_label":"Build","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate","name":"Build App"},
          {"agent":"pi","agent_status":"working","cwd":"/one/project/app","pane_id":"c","tab_label":"Build","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/two/project/app","pane_id":"d","tab_label":"Build","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"π · firstmate"},
          {"agent":"pi","agent_status":"working","cwd":"/work/docs","pane_id":"e","tab_label":"Build","tab_id":"t2","workspace_id":"w1","focused":false}
        ]}}
        """
        let entries = try HerdrConnection.decode(rows, as: AgentListResult.self).agents.map { entry in
            var entry = entry
            entry.workspaceLabel = example.label
            return entry
        }
        let items = AgentListItem.grouped(in: Space.join(workspaces: [example], agents: entries))
            .flatMap(\.items).sorted { $0.id < $1.id }
        let context = ["Review", "Build App", "/one/project/app", "/two/project/app", "~/work/docs"]
        #expect(items.map { AgentListPresentation(agent: $0.agent, peers: entries).title } == Array(repeating: "ExampleApp", count: 5))
        #expect(items.compactMap { AgentListPresentation(agent: $0.agent, peers: entries).subtitle(connectionHost: "studio")?.text }
            == context.map { "studio · \($0)" })
    }

    @Test
    func equallyNamedWorkspacesKeepTabAndAgentRolesDistinct() throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/app","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build","tab_label":"Build","name":"Review"},
          {"agent":"pi","agent_status":"working","cwd":"/work/app","pane_id":"b","tab_id":"t1","workspace_id":"w2","focused":false,"terminal_title_stripped":"Build","tab_label":"Review"}
        ]}}
        """
        let entries = try HerdrConnection.decode(rows, as: AgentListResult.self).agents.map { entry in
            var entry = entry
            entry.workspaceLabel = "ExampleApp"
            return entry
        }
        let shownTogether = entries.map { AgentListPresentation(agent: $0, peers: entries) }
        #expect(shownTogether.map(\.title) == ["ExampleApp", "ExampleApp"])
        #expect(shownTogether.compactMap { $0.subtitle(connectionHost: "studio")?.text } == [
            "studio · Tab: Build",
            "studio · Tab: Review"
        ])
    }

    @Test
    func priorityTiesUseTerminalTitles() throws {
        let example = workspace("ExampleApp")
        let entries = [
            try decodeAgent(name: "null", paneID: "p1", terminal: "Zulu"),
            try decodeAgent(name: "null", paneID: "p2", terminal: "Alpha")
        ].map { entry in
            var entry = entry
            entry.workspaceLabel = example.label
            return entry
        }
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

        #expect(items.first { $0.id == "studio/t1" }.map { AgentListPresentation(agent: $0.agent).title } == "firstmate")
        #expect(items.first { $0.id == "studio/peer/t2" }.map { AgentListPresentation(agent: $0.agent).title } == "2ndmate-tingxiemao")
        #expect(items.first { $0.id == "studio/peer/t3" }.map { AgentListPresentation(agent: $0.agent).title } == "First terminal")
        #expect(items.first { $0.id == "t4" }.map { AgentListPresentation(agent: $0.agent).title } == "Second terminal")
        #expect(items.first { $0.id == "t5" }.map { AgentListPresentation(agent: $0.agent).title } == "iap-impl")
        let subtitles = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            AgentListPresentation(agent: item.agent).subtitle(connectionHost: "gateway").map { (item.id, $0.text) }
        })
        #expect(subtitles["studio/t1"] == "studio · π · firstmate")
        #expect(subtitles["studio/peer/t2"] == "peer · π · firstmate")
        #expect(subtitles["studio/peer/t3"] == "peer")
        #expect(subtitles["t4"] == "gateway")
    }
}

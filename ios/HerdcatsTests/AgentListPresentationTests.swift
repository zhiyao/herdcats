import Foundation
import Testing
@testable import Herdcats

@Suite("Agent list presentation")
struct AgentListPresentationTests {
    private func workspace(_ label: String, worktree: Worktree? = nil) -> Workspace {
        Workspace(
            workspaceId: "w1", label: label, number: 1, tabCount: 1, paneCount: 1,
            activeTabId: "t1", agentStatus: "working", focused: true, worktree: worktree
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
        var entry = try decodeAgent(name: #""iap-impl""#)
        entry.tabLabel = tabLabel
        #expect(AgentListPresentation(agent: entry, workspace: workspace("")).title == tabLabel)
        let presentation = AgentListPresentation(agent: entry, workspace: workspace(" firstmate "))
        #expect(presentation.title == " firstmate ")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · π · firstmate")
        #expect(entry.displayTitle == "π · firstmate")
        #expect(entry.stateChangeSeq == 10)
        #expect(entry.agentStatus == "working")

        let agent = try decodeAgent(name: #"" iap-impl ""#)
        #expect(AgentListPresentation(agent: agent, workspace: workspace(" ")).title == " iap-impl ")
    }

    @Test(arguments: ["null", #""   ""#])
    func tuiMissingNamesUseTerminalTitleAndKeepMachineContext(name: String) throws {
        var entry = try decodeAgent(name: name)
        entry.tabLabel = " "
        let presentation = AgentListPresentation(agent: entry, workspace: workspace(""))
        #expect(presentation.title == "π · firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac")
        #expect(presentation.subtitle(connectionHost: nil) == nil)
    }

    @Test
    func tuiSubtitleOmitsDirectoryWithoutConfiguredFolder() throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/tmp/scratch","foreground_cwd":"/tmp/agent-job","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"}
        ]}}
        """
        let agent = try #require(HerdrConnection.decode(rows, as: AgentListResult.self).agents.first)
        let blankFolder = Worktree(checkoutPath: " ", repoName: "app", repoRoot: "/repos/app", isLinkedWorktree: true)
        for worktree in [nil, blankFolder] {
            let presentation = AgentListPresentation(agent: agent, workspace: workspace("", worktree: worktree))
            #expect(presentation.subtitle(connectionHost: "studio")?.text == "studio")
        }
        #expect(agent.shortCwd == "~/tmp/scratch")
    }

    @Test(arguments: ["null", #""/old/launch""#, #""/tmp/scratch""#])
    func tuiSubtitleUsesConfiguredFolderAndRawTerminalTitle(cwd: String) throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":\(cwd),"foreground_cwd":"/tmp/agent-job","pane_id":"p1","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title":" Review ","terminal_title_stripped":null}
        ]}}
        """
        let agent = try #require(HerdrConnection.decode(rows, as: AgentListResult.self).agents.first)
        let example = workspace("ExampleApp", worktree: Worktree(
            checkoutPath: "/repos/example ", repoName: "app", repoRoot: "/repos/app", isLinkedWorktree: true
        ))
        let presentation = AgentListPresentation(agent: agent, workspace: example)
        let directory = "~/repos/example "
        #expect(presentation.title == "ExampleApp")
        #expect(presentation.subtitle(connectionHost: "studio")?.text == "studio · \(directory) ·  Review ")
        #expect(agent.displayTitle == "p1")

        let repeatedDirectory = rows.replacingOccurrences(of: " Review ", with: directory)
        let repeatedAgent = try #require(
            HerdrConnection.decode(repeatedDirectory, as: AgentListResult.self).agents.first
        )
        let deduplicated = AgentListPresentation(agent: repeatedAgent, workspace: example)
        #expect(deduplicated.subtitle(connectionHost: "studio")?.text == "studio · \(directory)")
        #expect(deduplicated.subtitle(connectionHost: nil)?.text == directory)
        #expect(deduplicated.subtitle(connectionHost: nil)?.isPath == true)
    }

    @Test(arguments: [#""p1""#, "null"])
    func tuiSubtitleKeepsSuppliedTitleMatchingPaneID(strippedTitle: String) throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/launch","pane_id":"p1","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title":"p1","terminal_title_stripped":\(strippedTitle)}
        ]}}
        """
        let agent = try #require(HerdrConnection.decode(rows, as: AgentListResult.self).agents.first)
        let presentation = AgentListPresentation(agent: agent, workspace: workspace("ExampleApp"))
        #expect(presentation.title == "ExampleApp")
        #expect(presentation.subtitle(connectionHost: "studio")?.text == "studio · p1")
    }

    @Test
    func matchingHeadlinesAndDirectoriesUseCompactDirectoryContext() throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/one/project/app","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build","name":"Review"},
          {"agent":"pi","agent_status":"working","cwd":"/two/project/app","pane_id":"b","tab_id":"t2","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"}
        ]}}
        """
        let entries = try HerdrConnection.decode(rows, as: AgentListResult.self).agents
        let example = workspace("ExampleApp", worktree: Worktree(
            checkoutPath: "/repos/project/app", repoName: "app", repoRoot: "/repos/app", isLinkedWorktree: true
        ))
        let presentations = entries.map { AgentListPresentation(agent: $0, workspace: example) }
        #expect(presentations.map(\.title) == ["ExampleApp", "ExampleApp"])
        #expect(presentations.compactMap { $0.subtitle(connectionHost: "studio")?.text } == [
            "studio · ~/project/app · Build",
            "studio · ~/project/app · Build"
        ])
    }

    @Test
    func priorityTiesUseTerminalTitles() throws {
        let example = workspace("ExampleApp")
        let entries = [
            try decodeAgent(name: "null", paneID: "p1", terminal: "Zulu"),
            try decodeAgent(name: "null", paneID: "p2", terminal: "Alpha")
        ]
        let space = Space(workspace: example, agents: entries)
        let items = entries.map { AgentListItem(space: space, agent: $0) }
        #expect(items.sorted(by: AgentListItem.attentionOrder).map(\.id) == ["p2", "p1"])
        let presentations = items.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace) }
        #expect(presentations.map(\.title) == ["ExampleApp", "ExampleApp"])
        #expect(presentations.compactMap { $0.subtitle(connectionHost: "studio")?.text } == [
            "studio · Zulu",
            "studio · Alpha"
        ])
    }

    @Test
    func coreUsesLayoutNamesAndKeepsStandaloneTerminalTitles() throws {
        let snapshot = try CoreSnapshot(subscription: JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"seq":1,"terminals":[
          {"address":"studio/t1","title":"π · firstmate","cwd":"/work/firstmate ","foreground":{"cwd":"/work/scratch"},"state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/peer/t2","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/peer/t3","title":"First terminal","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"t4","title":"Second terminal","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"t5","name":"iap-impl","title":"Third terminal","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/t9","title":"studio/t9","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/t6","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/t7","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"studio/peer/t8","title":"π · firstmate","state":"live","status":{"app":"pi","state":"working"}}
        ]}
        """.utf8)))
        let layout = try JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"spaces":[
          {"id":"w1","name":" firstmate ","tabs":[
            {"id":"t1","name":"Main","root":{"content":{"terminal":"t1"}}},
            {"id":"t6","root":{"content":{"terminal":"t6"}}},
            {"id":"t9","root":{"content":{"terminal":"t9"}}}
          ]},
          {"id":"w2","name":" ","folder":"/work/firstmate","tabs":[
            {"id":"t2","name":"2ndmate-tingxiemao","root":{"content":{"terminal":"peer/t2"}}}
          ]},
          {"id":"w8","folder":"/work/secondmate ","tabs":[
            {"id":"t8","name":"2ndmate-tingxiemao","root":{"content":{"terminal":"peer/t8"}}}
          ]}
        ]}
        """.utf8))
        let hierarchy = snapshot.presentation(layout: nil, remoteLayouts: ["studio": layout])
        let spaces = Space.join(workspaces: hierarchy.workspaces, agents: hierarchy.agents)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)

        #expect(items.first { $0.id == "studio/t1" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == " firstmate ")
        #expect(items.first { $0.id == "studio/peer/t2" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "2ndmate-tingxiemao")
        #expect(items.first { $0.id == "studio/peer/t3" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "First terminal")
        #expect(items.first { $0.id == "t4" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "Second terminal")
        #expect(items.first { $0.id == "t5" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "Third terminal")
        let subtitles = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            AgentListPresentation(agent: item.agent, workspace: item.space.workspace).subtitle(connectionHost: "gateway").map { (item.id, $0.text) }
        })
        let namedWithoutTerminalTitle = try #require(items.first { $0.id == "studio/t6" })
        let standaloneWithoutTerminalTitle = try #require(items.first { $0.id == "studio/t7" })
        #expect(AgentListPresentation(agent: namedWithoutTerminalTitle.agent, workspace: namedWithoutTerminalTitle.space.workspace).title == " firstmate ")
        #expect(namedWithoutTerminalTitle.agent.displayTitle == "studio/t6")
        #expect(AgentListPresentation(agent: standaloneWithoutTerminalTitle.agent, workspace: standaloneWithoutTerminalTitle.space.workspace).title == "studio/t7")
        #expect(subtitles["studio/t6"] == "studio")
        #expect(subtitles["studio/t9"] == "studio · studio/t9")
        #expect(subtitles["studio/t7"] == "studio")
        #expect(subtitles["studio/t1"] == "studio · ~/work/firstmate  · π · firstmate")
        #expect(items.first { $0.id == "studio/t1" }?.agent.shortCwd == "~/work/scratch")
        #expect(subtitles["studio/peer/t2"] == "studio/peer · ~/work/firstmate · π · firstmate")
        #expect(subtitles["studio/peer/t8"] == "studio/peer · ~/work/secondmate  · π · firstmate")
        #expect(subtitles["studio/peer/t3"] == "studio/peer")
        #expect(subtitles["t4"] == "gateway")
    }

    @Test
    func nestedCoreMachineRoutesStayDistinctBeforeTerminal() throws {
        let snapshot = try CoreSnapshot(subscription: JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"seq":1,"terminals":[
          {"address":"studio/peer/t1","title":"Shared","state":"live","status":{"app":"pi","state":"working"}},
          {"address":"lab/peer/t1","title":"Shared","state":"live","status":{"app":"pi","state":"working"}}
        ]}
        """.utf8)))
        let studio = try JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"spaces":[{"id":"w","name":"ExampleApp","tabs":[
          {"id":"t","name":"Main","root":{"content":{"terminal":"peer/t1"}}}
        ]}]}
        """.utf8))
        let lab = try JSONDecoder().decode(CoreJSON.self, from: Data("""
        {"spaces":[{"id":"w","name":"ExampleApp","tabs":[
          {"id":"t","name":"Main","root":{"content":{"terminal":"peer/t1"}}}
        ]}]}
        """.utf8))
        let hierarchy = snapshot.presentation(layout: nil, remoteLayouts: ["studio": studio, "lab": lab])
        let spaces = Space.join(workspaces: hierarchy.workspaces, agents: hierarchy.agents)
        let items = AgentListItem.grouped(in: spaces).flatMap(\.items)
        let subtitles = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            AgentListPresentation(agent: item.agent, workspace: item.space.workspace)
                .subtitle(connectionHost: "gateway")
                .map { (item.id, $0.text) }
        })
        #expect(subtitles["studio/peer/t1"] == "studio/peer · Shared")
        #expect(subtitles["lab/peer/t1"] == "lab/peer · Shared")
        #expect(subtitles["studio/peer/t1"] != subtitles["lab/peer/t1"])
    }
}

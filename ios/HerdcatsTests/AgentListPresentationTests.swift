@testable import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
import Observation
import Testing
@testable import Herdcats

@Suite("Agent list presentation")
struct AgentListPresentationTests {
    @MainActor
    @Test
    func mountedTabsRefreshOverviewWhenReadyAndForceQuotaOnlyWhenReturningFromOffline() {
        let online = AppModel.Phase.connected(host: "studio", username: "demo")
        let offline = AppModel.Phase.offline(host: "studio", username: "demo")
        #expect(ConnectedTabsView.refreshAfterReconnect(from: .connecting, to: online) == .overview)
        #expect(ConnectedTabsView.refreshAfterReconnect(from: offline, to: online) == .overviewAndQuota)
        #expect(ConnectedTabsView.refreshAfterReconnect(from: offline, to: .connecting) == nil)
        #expect(ConnectedTabsView.refreshAfterReconnect(from: .disconnected, to: online) == nil)
        #expect(ConnectedTabsView.refreshAfterReconnect(from: online, to: online) == nil)
    }

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

    #if DEBUG
    private actor OverviewReplies {
        var replies: [HerdrConnection.OverviewRead: String]
        let heldRead: HerdrConnection.OverviewRead
        nonisolated let entered = ExternallyReleasedWait<Void>()
        nonisolated let release = ExternallyReleasedWait<Void>()
        private(set) var requests: Set<HerdrConnection.OverviewRead> = []
        private var nextReply: (String?, ExternallyReleasedWait<Void>, ExternallyReleasedWait<Void>)?

        init(_ replies: [HerdrConnection.OverviewRead: String], heldRead: HerdrConnection.OverviewRead) {
            self.replies = replies
            self.heldRead = heldRead
        }

        func response(to read: HerdrConnection.OverviewRead) async throws -> String {
            requests.insert(read)
            if read == heldRead {
                if let (reply, entered, release) = nextReply {
                    entered.release(())
                    try await release.wait()
                    guard let reply else {
                        throw HerdrError.api(code: "not_found", message: "Workspace closed")
                    }
                    return reply
                }
                entered.release(())
                try await release.wait()
            }
            guard let reply = replies[read] else {
                throw HerdrError.api(code: "not_found", message: "Workspace closed")
            }
            return reply
        }

        func holdReply(_ reply: String?) -> (ExternallyReleasedWait<Void>, ExternallyReleasedWait<Void>) {
            let entered = ExternallyReleasedWait<Void>()
            let release = ExternallyReleasedWait<Void>()
            nextReply = (reply, entered, release)
            return (entered, release)
        }

        func update(_ read: HerdrConnection.OverviewRead, reply: String?) {
            replies[read] = reply
        }
    }

    @MainActor
    @Test
    func tuiPollKeepsSettledLabelsWhenWorkspaceBecomesEmptyAndReturns() async throws {
        let workspaces = """
        {"result":{"workspaces":[
          {"workspace_id":"w0","label":"","number":1,"tab_count":1,"pane_count":1,"active_tab_id":"t","agent_status":"working","focused":true},
          {"workspace_id":"w1","label":"","number":2,"tab_count":1,"pane_count":1,"active_tab_id":"t","agent_status":"working","focused":false},
          {"workspace_id":"w2","label":"","number":3,"tab_count":1,"pane_count":1,"active_tab_id":"t","agent_status":"working","focused":false}
        ]}}
        """
        let firstAgent = #"{"agent":"pi","agent_status":"working","pane_id":"p0","tab_id":"t","workspace_id":"w0","focused":true}"#
        let secondAgent = #"{"agent":"pi","agent_status":"working","pane_id":"p1","tab_id":"t","workspace_id":"w1","focused":false}"#
        let thirdAgent = #"{"agent":"pi","agent_status":"working","pane_id":"p2","tab_id":"t","workspace_id":"w2","focused":false}"#
        let firstTabs = HerdrConnection.OverviewRead.tabs(workspaceId: "w0")
        let secondTabs = HerdrConnection.OverviewRead.tabs(workspaceId: "w1")
        let thirdTabs = HerdrConnection.OverviewRead.tabs(workspaceId: "w2")
        let secondTabResponse = #"{"result":{"tabs":[{"tab_id":"t","workspace_id":"w1","label":"Second tab","number":1,"pane_count":1,"agent_status":"working","focused":false}]}}"#
        let replies = OverviewReplies([
            .workspaces: workspaces,
            .agents: #"{"result":{"agents":[\#(firstAgent),\#(secondAgent)]}}"#,
            firstTabs: #"{"result":{"tabs":[{"tab_id":"t","workspace_id":"w0","label":"First tab","number":1,"pane_count":1,"agent_status":"working","focused":true}]}}"#,
            secondTabs: secondTabResponse,
            thirdTabs: #"{"result":{"tabs":[{"tab_id":"t","workspace_id":"w2","label":"Third tab","number":1,"pane_count":1,"agent_status":"working","focused":false}]}}"#
        ], heldRead: secondTabs)
        let reads = NIOLockedValueBox<[HerdrConnection.OverviewRead]>([])
        let connection = HerdrConnection(overviewResponse: { read in
            if case .tabs = read { reads.withLockedValue { $0.append(read) } }
            return try await replies.response(to: read)
        })
        let model = SpacesModel()
        defer { replies.release.release(()) }

        await model.refresh(connection)
        try await withTimeout(seconds: 3, label: "second workspace lookup") { try await replies.entered.wait() }
        #expect(model.spaces.flatMap(\.agents).compactMap(\.tabLabel) == ["First tab"])
        await replies.update(.agents, reply: #"{"result":{"agents":[\#(secondAgent),\#(thirdAgent)]}}"#)
        let poll = Task { await model.refresh(connection, isPoll: true) }
        try await withTimeout(seconds: 3, label: "poll base refresh") { await poll.value }
        #expect(model.spaces.flatMap(\.agents).map(\.paneId) == ["p1", "p2"])
        #expect(model.spaces.flatMap(\.agents).compactMap(\.tabLabel).isEmpty)
        #expect(reads.withLockedValue { $0 } == [firstTabs, secondTabs])

        let (successorEntered, finishSuccessorRead) = await replies.holdReply(secondTabResponse)
        defer { finishSuccessorRead.release(()) }
        replies.release.release(())
        try await withTimeout(seconds: 3, label: "successor workspace lookup") { try await successorEntered.wait() }
        await replies.update(.agents, reply: #"{"result":{"agents":[\#(firstAgent),\#(secondAgent),\#(thirdAgent)]}}"#)
        await model.refresh(connection, isPoll: true)
        #expect(model.spaces.flatMap(\.agents).map(\.paneId) == ["p0", "p1", "p2"])
        #expect(model.spaces.flatMap(\.agents).compactMap(\.tabLabel) == ["First tab"])
        #expect(reads.withLockedValue { $0 } == [firstTabs, secondTabs, secondTabs])
        finishSuccessorRead.release(())
        await model.waitForTabEnrichment()
        #expect(model.spaces.flatMap(\.agents).compactMap(\.tabLabel) == ["First tab", "Second tab", "Third tab"])
        #expect(reads.withLockedValue { $0 } == [firstTabs, secondTabs, secondTabs, thirdTabs])
    }

    @MainActor
    @Test(arguments: [false, true])
    func tuiRefreshPublishesBaseBeforeScopedTabLookup(expiresWhileWaiting: Bool) async throws {
        let workspacesJSON = """
        {"result":{"workspaces":[
          {"workspace_id":"w0","label":"","number":1,"tab_count":1,"pane_count":1,"active_tab_id":"t-review","agent_status":"working","focused":false},
          {"workspace_id":"w1","label":" ","number":2,"tab_count":2,"pane_count":2,"active_tab_id":"t-review","agent_status":"working","focused":true},
          {"workspace_id":"w2","label":"Named","number":3,"tab_count":1,"pane_count":1,"active_tab_id":"t-review","agent_status":"working","focused":false}
        ]}}
        """
        let agentsJSON = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","pane_id":"p0","tab_id":"t-review","workspace_id":"w0","focused":false,"terminal_title_stripped":"Closed"},
          {"agent":"pi","agent_status":"working","cwd":"/work/a","pane_id":"p1","tab_id":"t-review","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build","tab_label":"Ignored"},
          {"agent":"pi","agent_status":"working","cwd":"/work/b","pane_id":"p2","tab_id":"t-implement","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build","tab_label":"Ignored"},
          {"agent":"pi","agent_status":"working","pane_id":"p3","tab_id":"t-review","workspace_id":"w2","focused":false,"terminal_title_stripped":"Build"}
        ]}}
        """
        let tabsJSON = """
        {"result":{"tabs":[
          {"tab_id":"t-review","workspace_id":"w1","label":" Review ","number":1,"pane_count":1,"agent_status":"working","focused":true},
          {"tab_id":"t-implement","workspace_id":"w1","label":"Implement","number":2,"pane_count":1,"agent_status":"working","focused":false}
        ]}}
        """
        let closedTabs = HerdrConnection.OverviewRead.tabs(workspaceId: "w0")
        let unnamedTabs = HerdrConnection.OverviewRead.tabs(workspaceId: "w1")
        let replies = OverviewReplies([
            .workspaces: workspacesJSON,
            .agents: agentsJSON,
            unnamedTabs: tabsJSON
        ], heldRead: unnamedTabs)
        let connection = HerdrConnection(overviewResponse: { try await replies.response(to: $0) })
        let model = SpacesModel()
        let deadline = ContinuousClock.now + (expiresWhileWaiting ? .seconds(1) : .seconds(10))
        let refresh = Task { await model.refresh(connection, deadline: deadline) }
        defer { replies.release.release(()) }
        try await withTimeout(seconds: 3, label: "tab lookup fixture") { try await replies.entered.wait() }

        func titles() -> [String] {
            model.spaces.flatMap { space in
                space.agents.map { AgentListPresentation(agent: $0, workspace: space.workspace).title }
            }
        }
        let baseTitles = ["Closed", "Build", "Build", "Named"]
        #expect(model.spaces.map(\.id) == ["w0", "w1", "w2"])
        #expect(titles() == baseTitles)
        #expect(model.hasLoadedAgentList)
        #expect(!model.isLoading)
        try await withTimeout(seconds: 3, label: "base refresh completion") { await refresh.value }
        await replies.update(.agents, reply: agentsJSON.replacingOccurrences(of: "\"working\"", with: "\"blocked\""))
        await model.refresh(connection, isPoll: true)
        #expect(model.spaces.flatMap(\.agents).allSatisfy { $0.agentStatus == "blocked" })
        if expiresWhileWaiting {
            model.isSceneActive = false
            try await ContinuousClock().sleep(until: deadline + .milliseconds(20))
            model.isSceneActive = true
            #expect(titles() == baseTitles)
            #expect(model.errorMessage == nil)
        }
        replies.release.release(())
        await model.waitForTabEnrichment()
        #expect(model.spaces.flatMap(\.agents).allSatisfy { $0.agentStatus == "blocked" })

        let verifiedTitles = ["Closed", " Review ", "Implement", "Named"]
        #expect(titles() == (expiresWhileWaiting ? baseTitles : verifiedTitles))
        if !expiresWhileWaiting {
            let (revalidating, finishRevalidation) = await replies.holdReply(
                tabsJSON.replacingOccurrences(of: " Review ", with: "Updated")
            )
            defer { finishRevalidation.release(()) }
            await model.refresh(connection)
            try await withTimeout(seconds: 3, label: "revalidation before failed refresh") { try await revalidating.wait() }
            await replies.update(.agents, reply: "{}")
            await model.refresh(connection)
            #expect(titles() == verifiedTitles)
            finishRevalidation.release(())
            await model.waitForTabEnrichment()
            let updatedTitles = ["Closed", "Updated", "Implement", "Named"]
            #expect(titles() == updatedTitles)
            await replies.update(.agents, reply: agentsJSON)

            let firstTab = """
            {"result":{"tabs":[
              {"tab_id":"t-review","workspace_id":"w0","label":"Verified first","number":1,"pane_count":1,"agent_status":"working","focused":true},
              {"tab_id":"t-late","workspace_id":"w0","label":"Late agent tab","number":2,"pane_count":1,"agent_status":"working","focused":false}
            ]}}
            """
            await replies.update(closedTabs, reply: firstTab)
            let (otherWorkspaceEntered, finishOtherWorkspace) = await replies.holdReply(tabsJSON)
            defer { finishOtherWorkspace.release(()) }
            await model.refresh(connection)
            try await withTimeout(seconds: 3, label: "workspace settling before sibling") { try await otherWorkspaceEntered.wait() }
            #expect(titles() == ["Verified first", "Updated", "Implement", "Named"])
            let lateAgent = """
            ,{"agent":"pi","agent_status":"working","pane_id":"p-late","tab_id":"t-late","workspace_id":"w0","focused":false,"terminal_title_stripped":"Late agent"}
            ]}}
            """
            await replies.update(.agents, reply: agentsJSON.replacingOccurrences(of: "]}}", with: lateAgent))
            await model.refresh(connection, isPoll: true)
            #expect(model.spaces.first?.agents.first { $0.paneId == "p-late" }?.tabLabel == "Late agent tab")
            finishOtherWorkspace.release(())
            await model.waitForTabEnrichment()
            #expect(model.spaces.first?.agents.first { $0.paneId == "p-late" }?.tabLabel == "Late agent tab")
            await replies.update(.agents, reply: agentsJSON)

            await replies.update(closedTabs, reply: #"{"result":{"tabs":[]}}"#)
            let (firstEntered, firstRelease) = await replies.holdReply(tabsJSON)
            defer { firstRelease.release(()) }
            let originalCutoff = ContinuousClock.now + .seconds(2)
            await model.refresh(connection, deadline: originalCutoff)
            try await withTimeout(seconds: 3, label: "second workspace pending") { try await firstEntered.wait() }
            #expect(titles() == verifiedTitles)

            let (successorEntered, successorRelease) = await replies.holdReply(tabsJSON)
            defer { successorRelease.release(()) }
            await model.refresh(connection)
            firstRelease.release(())
            try await withTimeout(seconds: 3, label: "successor workspace pending") { try await successorEntered.wait() }
            #expect(titles() == verifiedTitles)
            try await ContinuousClock().sleep(until: originalCutoff + .milliseconds(100))
            #expect(titles() == baseTitles)
            successorRelease.release(())
            await model.waitForTabEnrichment()
            #expect(titles() == verifiedTitles)
            await replies.update(closedTabs, reply: nil)

            let renamedTabs = """
            {"result":{"tabs":[
              {"tab_id":"t-review","workspace_id":"w1","label":"Renamed","number":1,"pane_count":1,"agent_status":"working","focused":true}
            ]}}
            """
            let renamedTitles = ["Closed", "Renamed", "Build", "Named"]
            for (reply, before, after, replaceSource) in [
                (renamedTabs as String?, verifiedTitles, renamedTitles, false),
                (nil, renamedTitles, baseTitles, false),
                (tabsJSON, baseTitles, verifiedTitles, false),
                (nil, baseTitles, baseTitles, true)
            ] {
                if replaceSource { await connection.close() }
                let (entered, release) = await replies.holdReply(reply)
                defer { release.release(()) }
                await model.refresh(connection)
                try await withTimeout(seconds: 3, label: "tab revalidation") { try await entered.wait() }
                #expect(titles() == before)
                release.release(())
                await model.waitForTabEnrichment()
                #expect(titles() == after)
            }
            let (entered, release) = await replies.holdReply(tabsJSON)
            defer { release.release(()) }
            await model.refresh(connection)
            try await withTimeout(seconds: 3, label: "tab revalidation before invalidation") { try await entered.wait() }
            model.discardTabLabels(fromOtherGeneration: nil)
            release.release(())
            await model.waitForTabEnrichment()
            #expect(titles() == baseTitles)
        }
        #expect(model.errorMessage == nil)
        #expect(model.spaces.last?.agents.first?.tabLabel == nil)
        await #expect(throws: HerdrError.notConnected) { try await connection.workspaceList() }
        await #expect(throws: HerdrError.notConnected) { try await connection.tabList(workspaceId: "w1") }
        await #expect(throws: HerdrError.notConnected) { try await connection.workspaceCreate() }
        let requests: Set<HerdrConnection.OverviewRead> = [.workspaces, .agents, closedTabs, unnamedTabs]
        #expect(await replies.requests == requests)
    }

    @Test
    func tabLabelLookupReportsSettledWorkspacesAndOmitsSkippedOnes() async throws {
        let held = HerdrConnection.OverviewRead.tabs(workspaceId: "c")
        let replies = OverviewReplies([
            .tabs(workspaceId: "a"): #"{"result":{"tabs":[]}}"#,
            held: #"{"result":{"tabs":[]}}"#
        ], heldRead: held)
        let connection = HerdrConnection(overviewResponse: { try await replies.response(to: $0) })
        let generation = await connection.generation
        let deadline = ContinuousClock.now + .seconds(1)
        let results = NIOLockedValueBox<[String: [String: String]]>([:])
        let lookup = Task {
            try await connection.agentTabLabels(
                workspaceIDs: ["a", "b", "c", "d"], generation: generation, deadline: deadline
            ) { workspace, labels in
                results.withLockedValue { $0[workspace] = labels }
            }
        }
        defer { replies.release.release(()) }
        try await withTimeout(seconds: 3, label: "lookup before budget expiry") { try await replies.entered.wait() }
        try await ContinuousClock().sleep(until: deadline)
        replies.release.release(())
        try await lookup.value
        #expect(results.withLockedValue { $0 } == ["a": [:], "b": [:], "c": [:]])
        #expect(!(await replies.requests).contains(.tabs(workspaceId: "d")))
    }
    #endif

    enum TabLookupStop: CaseIterable {
        case cancellation, deadline, ownerRevocation
    }

    @Test(arguments: TabLookupStop.allCases)
    func optionalTabLookupClosesOnlyDisposableConnection(stop: TabLookupStop) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let fixture = DelayedTabChannel()
        let server = try await fixture.listen(on: group)
        var client: SSHClient?
        do {
            let port = try #require(server.localAddress?.port)
            let ssh = try await SSHClient.connect(to: SSHClientSettings(
                host: "127.0.0.1", port: port,
                authenticationMethod: { .passwordBased(username: "fixture", password: "fixture") },
                hostKeyValidator: .acceptAnything()
            ))
            client = ssh
            try #require(ssh.allowOptionalTabList())
            await #expect(throws: CitadelError.channelCreationFailed) {
                try await ssh.executeOptionalTabList("expired", deadline: ContinuousClock.now)
            }
            let lookup = Task {
                try await ssh.executeOptionalTabList(
                    "late",
                    deadline: ContinuousClock.now.advanced(by: stop == .deadline ? .seconds(2) : .seconds(10))
                )
            }
            let confirmOpen = try await withTimeout(seconds: 3, label: "pending SSH open") {
                try await fixture.pendingOpen.wait()
            }
            switch stop {
            case .cancellation:
                lookup.cancel()
            case .deadline:
                break
            case .ownerRevocation:
                let connection = HerdrConnection()
                await connection.installFixtureClient(ssh)
                let owned = await connection.generation
                await connection.handleDisconnect(expected: ConnectionGeneration(rawValue: owned.rawValue + 1))
                #expect(await connection.generation == owned)
                #expect(await connection.client === ssh)
                await connection.handleDisconnect(expected: owned)
                #expect(await connection.generation != owned)
            }
            do {
                _ = try await withTimeout(seconds: 4, label: "lookup socket teardown") {
                    try await lookup.value
                }
                Issue.record("The unanswered lookup returned output")
            } catch {
                #expect(error as? HerdrError != .timeout("lookup socket teardown"))
                if stop == .cancellation { #expect(error is CancellationError) }
            }
            try await withTimeout(seconds: 3, label: "lookup socket close") { try await fixture.closed.wait() }
            confirmOpen.succeed(())

            let primary = try await ssh.executeCommand("primary")
            #expect(String(buffer: primary) == "primary")
            let nextDeadline = ContinuousClock.now + .seconds(3)
            if stop == .ownerRevocation {
                #expect(!ssh.allowOptionalTabList())
                await #expect(throws: CitadelError.channelCreationFailed) {
                    try await ssh.executeOptionalTabList("next", deadline: nextDeadline)
                }
                #expect(fixture.commands.withLockedValue { $0 } == ["primary"])
            } else {
                let output = try await ssh.executeOptionalTabList("next", deadline: nextDeadline)
                #expect(String(buffer: output) == "next")
                #expect(fixture.commands.withLockedValue { $0 } == ["primary", "next"])
            }
        } catch {
            try? await client?.close()
            try? await server.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try await client?.close()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test
    func optionalTabReaderRejectsExecAfterDeadlineOnOpenTransport() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let fixture = DelayedTabChannel()
        let server = try await fixture.listen(on: group)
        var client: SSHClient?
        do {
            let port = try #require(server.localAddress?.port)
            let ssh = try await SSHClient.connect(to: SSHClientSettings(
                host: "127.0.0.1", port: port,
                authenticationMethod: { .passwordBased(username: "fixture", password: "fixture") },
                hostKeyValidator: .acceptAnything()
            ))
            client = ssh
            let session = ssh.session
            let deadline = ContinuousClock.now + .seconds(2)
            let query = OptionalTabListQuery(owner: session.channel, deadline: deadline)
            let lookup = Task { try await session.readOptionalTabList("late", query: query) }
            let confirmOpen = try await withTimeout(seconds: 3, label: "pending SSH open") {
                try await fixture.pendingOpen.wait()
            }
            try await ContinuousClock().sleep(until: deadline)
            confirmOpen.succeed(())

            await #expect(throws: CitadelError.channelCreationFailed) {
                try await withTimeout(seconds: 3, label: "expired tab read") { try await lookup.value }
            }
            let nextQuery = OptionalTabListQuery(owner: session.channel, deadline: ContinuousClock.now + .seconds(3))
            let output = try await withTimeout(seconds: 3, label: "healthy tab read") {
                try await session.readOptionalTabList("next", query: nextQuery)
            }
            #expect(String(buffer: output) == "next")
            #expect(fixture.commands.withLockedValue { $0 } == ["next"])
        } catch {
            try? await client?.close()
            try? await server.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try await client?.close()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @MainActor
    @Test(arguments: [false, true])
    func optionalAdmissionGuardsConnectionTransitions(revokedDuringReadiness: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let fixture = DelayedTabChannel(delayAuthentication: true)
        let server = try await fixture.listen(on: group)
        let connection = HerdrConnection()
        do {
            let port = try #require(server.localAddress?.port)
            let ssh = try await SSHClient.connect(to: SSHClientSettings(
                host: "127.0.0.1", port: port,
                authenticationMethod: { .passwordBased(username: "fixture", password: "fixture") },
                hostKeyValidator: .acceptAnything()
            ))
            let app = AppModel(connection: connection, autoConnectOnLaunch: false)
            app.customDialTransport = { _, reserved, _ in
                await connection.installFixtureClient(ssh)
                return reserved
            }
            app.customCheckHerdr = { _, _ in
                await #expect(throws: CitadelError.channelCreationFailed) {
                    try await ssh.executeOptionalTabList("unready", deadline: ContinuousClock.now + .seconds(1))
                }
                #expect(fixture.acceptedConnections == 1)
                if revokedDuringReadiness { ssh.invalidateOptionalTabList() }
                return "herdr fixture"
            }
            await app.connect(config: ConnectionConfig(
                host: "127.0.0.1", port: port, username: "fixture", auth: .password("fixture")
            ))
            if revokedDuringReadiness {
                #expect(app.phase == .disconnected)
                #expect(!app.hasActiveSession)
            } else {
                #expect(app.phase == .connected(host: "127.0.0.1", username: "fixture"))
                let lookup = Task {
                    try await ssh.executeOptionalTabList("late", deadline: ContinuousClock.now + .seconds(10))
                }
                let authenticate = try await withTimeout(seconds: 3, label: "pending SSH authentication") {
                    try await fixture.pendingAuthentication.wait()
                }
                defer { authenticate.succeed(.success) }
                let admissionAtDisconnect = NIOLockedValueBox<(primaryConnected: Bool, allowed: Bool)?>(nil)
                withObservationTracking {
                    _ = app.hasActiveSession
                } onChange: {
                    admissionAtDisconnect.withLockedValue { $0 = (ssh.isConnected, ssh.allowOptionalTabList()) }
                }
                await app.disconnect()
                let admission = try #require(admissionAtDisconnect.withLockedValue { $0 })
                #expect(admission.primaryConnected)
                #expect(!admission.allowed)
                #expect(app.phase == .disconnected)
                try await withTimeout(seconds: 3, label: "lookup socket close") { try await fixture.closed.wait() }
                await #expect(throws: CitadelError.channelCreationFailed) {
                    try await withTimeout(seconds: 3, label: "lookup completion") { try await lookup.value }
                }
            }
            #expect(fixture.commands.withLockedValue { $0 }.isEmpty)
            await connection.close()
        } catch {
            await connection.close()
            try? await server.close()
            try? await group.shutdownGracefully()
            throw error
        }
        try await server.close()
        try await group.shutdownGracefully()
    }
}

private extension HerdrConnection {
    func installFixtureClient(_ client: SSHClient) {
        _ = slot.install(client, expected: generation)
    }
}

private final class DelayedTabChannel: Sendable {
    let pendingAuthentication = ExternallyReleasedWait<EventLoopPromise<NIOSSHUserAuthenticationOutcome>>()
    let pendingOpen = ExternallyReleasedWait<EventLoopPromise<Void>>()
    let closed = ExternallyReleasedWait<Void>()
    let commands = NIOLockedValueBox<[String]>([])
    private let socketCount = NIOLockedValueBox(0)
    var acceptedConnections: Int { socketCount.withLockedValue { $0 } }
    private let childCount = NIOLockedValueBox(0)
    private let delayAuthentication: Bool

    init(delayAuthentication: Bool = false) {
        self.delayAuthentication = delayAuthentication
    }

    func listen(on group: MultiThreadedEventLoopGroup) async throws -> Channel {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        return try await ServerBootstrap(group: group).childChannelInitializer { channel in
            let socket = channel
            let index = self.socketCount.withLockedValue { count in
                count += 1
                return count
            }
            let pendingAuthentication = self.delayAuthentication && index == 2 ? self.pendingAuthentication : nil
            if pendingAuthentication != nil {
                socket.closeFuture.whenComplete { _ in self.closed.release(()) }
            }
            return channel.pipeline.addHandler(NIOSSHHandler(
                role: .server(SSHServerConfiguration(hostKeys: [key], userAuthDelegate: TabFixtureAuthentication(pending: pendingAuthentication))),
                allocator: channel.allocator,
                inboundChildChannelInitializer: { child, _ in
                    let index = self.childCount.withLockedValue { count in
                        count += 1
                        return count
                    }
                    return child.pipeline.addHandler(TabFixtureExec(commands: self.commands)).flatMap {
                        guard !self.delayAuthentication, index == 1 else { return child.eventLoop.makeSucceededVoidFuture() }
                        socket.closeFuture.whenComplete { _ in self.closed.release(()) }
                        let confirmOpen = child.eventLoop.makePromise(of: Void.self)
                        self.pendingOpen.release(confirmOpen)
                        return confirmOpen.futureResult
                    }
                }
            ))
        }.bind(host: "127.0.0.1", port: 0).get()
    }
}

private struct TabFixtureAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let pending: ExternallyReleasedWait<EventLoopPromise<NIOSSHUserAuthenticationOutcome>>?
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        if let pending {
            pending.release(responsePromise)
        } else {
            responsePromise.succeed(.success)
        }
    }
}

private final class TabFixtureExec: ChannelInboundHandler, Sendable {
    typealias InboundIn = SSHChannelData
    let commands: NIOLockedValueBox<[String]>

    init(commands: NIOLockedValueBox<[String]>) {
        self.commands = commands
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else {
            context.fireUserInboundEventTriggered(event)
            return
        }
        commands.withLockedValue { $0.append(request.command) }
        context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: request.command)))
        context.writeAndFlush(NIOAny(data), promise: nil)
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
        context.close(promise: nil)
    }
}

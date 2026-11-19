import Citadel
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSH
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
        let presentation = AgentListPresentation(agent: entry, workspace: workspace("firstmate"))
        #expect(presentation.title == "firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · ~/1/firstmate · π · firstmate")
        #expect(entry.displayTitle == "π · firstmate")
        #expect(entry.stateChangeSeq == 10)
        #expect(entry.agentStatus == "working")

        let agent = try decodeAgent(name: #""iap-impl""#)
        #expect(AgentListPresentation(agent: agent, workspace: workspace("")).title == "iap-impl")
    }

    @Test(arguments: ["null", #""   ""#])
    func tuiMissingNamesUseTerminalTitleAndKeepMachineContext(name: String) throws {
        var entry = try decodeAgent(name: name)
        entry.tabLabel = " "
        let presentation = AgentListPresentation(agent: entry, workspace: workspace(""))
        #expect(presentation.title == "π · firstmate")
        #expect(presentation.subtitle(connectionHost: "studio-mac")?.text == "studio-mac · ~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.text == "~/1/firstmate")
        #expect(presentation.subtitle(connectionHost: nil)?.isPath == true)
    }

    @Test
    func tuiOverviewUsesLaunchDirectory() throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":"/work/launch","foreground_cwd":"/work/scratch","pane_id":"a","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title_stripped":"Build"}
        ]}}
        """
        let agent = try #require(HerdrConnection.decode(rows, as: AgentListResult.self).agents.first)
        #expect(AgentListPresentation(agent: agent, workspace: workspace("")).subtitle(connectionHost: "studio")?.text == "studio · ~/work/launch")
    }

    @Test(arguments: ["null", #""  ""#, #""/work/launch ""#])
    func tuiSubtitleUsesAvailableDirectoryAndRawTerminalTitle(cwd: String) throws {
        let rows = """
        {"result":{"agents":[
          {"agent":"pi","agent_status":"working","cwd":\(cwd),"pane_id":"p1","tab_id":"t1","workspace_id":"w1","focused":false,"terminal_title":"Review","terminal_title_stripped":null}
        ]}}
        """
        let agent = try #require(HerdrConnection.decode(rows, as: AgentListResult.self).agents.first)
        let example = workspace("ExampleApp", worktree: Worktree(
            checkoutPath: "/repos/example ", repoName: "app", repoRoot: "/repos/app", isLinkedWorktree: true
        ))
        let presentation = AgentListPresentation(agent: agent, workspace: example)
        let directory = cwd == #""/work/launch ""# ? "~/work/launch " : "~/repos/example "
        #expect(presentation.title == "ExampleApp")
        #expect(presentation.subtitle(connectionHost: "studio")?.text == "studio · \(directory) · Review")
        #expect(agent.displayTitle == "p1")
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
        #expect(presentation.subtitle(connectionHost: "studio")?.text == "studio · ~/work/launch · p1")
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
        let example = workspace("ExampleApp")
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
            "studio · ~/1/firstmate · Zulu",
            "studio · ~/1/firstmate · Alpha"
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
          {"id":"w1","name":"firstmate","tabs":[
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

        #expect(items.first { $0.id == "studio/t1" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "firstmate")
        #expect(items.first { $0.id == "studio/peer/t2" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "2ndmate-tingxiemao")
        #expect(items.first { $0.id == "studio/peer/t3" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "First terminal")
        #expect(items.first { $0.id == "t4" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "Second terminal")
        #expect(items.first { $0.id == "t5" }.map { AgentListPresentation(agent: $0.agent, workspace: $0.space.workspace).title } == "iap-impl")
        let subtitles = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            AgentListPresentation(agent: item.agent, workspace: item.space.workspace).subtitle(connectionHost: "gateway").map { (item.id, $0.text) }
        })
        let namedWithoutTerminalTitle = try #require(items.first { $0.id == "studio/t6" })
        let standaloneWithoutTerminalTitle = try #require(items.first { $0.id == "studio/t7" })
        #expect(AgentListPresentation(agent: namedWithoutTerminalTitle.agent, workspace: namedWithoutTerminalTitle.space.workspace).title == "firstmate")
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
        let replies: [String: String]
        let heldCommand: String
        nonisolated let entered = ExternallyReleasedWait<Void>()
        nonisolated let release = ExternallyReleasedWait<Void>()
        private(set) var requests: Set<String> = []

        init(_ replies: [String: String], heldCommand: String) {
            self.replies = replies
            self.heldCommand = heldCommand
        }

        func response(to command: String) async throws -> String {
            requests.insert(command)
            if command == heldCommand {
                entered.release(())
                try await release.wait()
            }
            guard let reply = replies[command] else {
                throw HerdrError.api(code: "not_found", message: "Workspace closed")
            }
            return reply
        }
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
          {"tab_id":"t-review","workspace_id":"w1","label":"Review","number":1,"pane_count":1,"agent_status":"working","focused":true},
          {"tab_id":"t-implement","workspace_id":"w1","label":"Implement","number":2,"pane_count":1,"agent_status":"working","focused":false}
        ]}}
        """
        let closedTabs = HerdrConnection.tabListArguments(workspaceId: "w0")
        let unnamedTabs = HerdrConnection.tabListArguments(workspaceId: "w1")
        let replies = OverviewReplies([
            "workspace list": workspacesJSON,
            "agent list": agentsJSON,
            unnamedTabs: tabsJSON
        ], heldCommand: unnamedTabs)
        let connection = HerdrConnection(herdrCommandResponse: { try await replies.response(to: $0) })
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
        if expiresWhileWaiting {
            model.isSceneActive = false
            try await ContinuousClock().sleep(until: deadline + .milliseconds(20))
            model.isSceneActive = true
            #expect(titles() == baseTitles)
            #expect(model.errorMessage == nil)
        }
        replies.release.release(())
        await refresh.value

        #expect(titles() == (expiresWhileWaiting ? baseTitles : ["Closed", "Review", "Implement", "Named"]))
        #expect(model.errorMessage == nil)
        #expect(model.spaces.last?.agents.first?.tabLabel == nil)
        let requests: Set<String> = ["workspace list", "agent list", closedTabs, unnamedTabs]
        #expect(await replies.requests == requests)
    }
    #endif

    @Test(arguments: [false, true])
    func optionalTabLookupClosesLateSSHChild(timedOut: Bool) async throws {
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
            let lookup = Task {
                try await withTimeout(seconds: timedOut ? 1 : 4, label: "optional tab list") {
                    try await ssh.executeOptionalTabList("late")
                }
            }
            let confirmOpen = try await withTimeout(seconds: 3, label: "pending SSH open") {
                try await fixture.pendingOpen.wait()
            }
            if !timedOut { lookup.cancel() }
            do {
                _ = try await lookup.value
                Issue.record("The lookup returned before the server confirmed the open")
            } catch {
                if timedOut {
                    #expect(error as? HerdrError == .timeout("optional tab list"))
                } else {
                    #expect(error is CancellationError)
                }
            }
            do {
                _ = try await withTimeout(seconds: 0.25, label: "another optional lookup") {
                    try await ssh.executeOptionalTabList("while pending")
                }
                Issue.record("A second optional lookup opened while the first was pending")
            } catch {
                #expect(error is CitadelError)
            }
            confirmOpen.succeed(())
            try await withTimeout(seconds: 3, label: "late child close") { try await fixture.closed.wait() }

            let output = try await withTimeout(seconds: 3, label: "next optional lookup") {
                while true {
                    do { return try await ssh.executeOptionalTabList("next") }
                    catch CitadelError.channelCreationFailed { try await Task.sleep(for: .milliseconds(10)) }
                }
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
}

private final class DelayedTabChannel: Sendable {
    let pendingOpen = ExternallyReleasedWait<EventLoopPromise<Void>>()
    let closed = ExternallyReleasedWait<Void>()
    let commands = NIOLockedValueBox<[String]>([])
    private let childCount = NIOLockedValueBox(0)

    func listen(on group: MultiThreadedEventLoopGroup) async throws -> Channel {
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        return try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.pipeline.addHandler(NIOSSHHandler(
                role: .server(SSHServerConfiguration(hostKeys: [key], userAuthDelegate: TabFixtureAuthentication())),
                allocator: channel.allocator,
                inboundChildChannelInitializer: { child, _ in
                    let index = self.childCount.withLockedValue { count in
                        count += 1
                        return count
                    }
                    return child.pipeline.addHandler(TabFixtureExec(commands: self.commands)).flatMap {
                        guard index == 1 else { return child.eventLoop.makeSucceededVoidFuture() }
                        child.closeFuture.whenComplete { _ in self.closed.release(()) }
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
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        responsePromise.succeed(.success)
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

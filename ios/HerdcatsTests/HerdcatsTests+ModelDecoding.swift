import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Herdr JSON decoding")
struct HerdrDecodingTests {
    @Test
    func decodesWorkspaceList() throws {
        let result = try HerdrConnection.decode(workspaceListJSON, as: WorkspaceListResult.self)
        let workspaces = result.workspaces
        #expect(workspaces.count == 3)

        let first = try #require(workspaces.first { $0.workspaceId == "w4" })
        #expect(first.label == "ExampleApp")
        #expect(first.number == 1)
        #expect(first.tabCount == 2)
        #expect(first.paneCount == 3)
        #expect(first.activeTabId == "w4:tD")
        #expect(first.agentStatus == "idle")
        #expect(first.focused == false)
        #expect(first.worktree?.repoName == "samplenotes")
        #expect(first.worktree?.isLinkedWorktree == false)

        let bare = try #require(workspaces.first { $0.workspaceId == "w32" })
        #expect(bare.worktree == nil)

        let focused = try #require(workspaces.first { $0.workspaceId == "w4H" })
        #expect(focused.focused == true)
        #expect(focused.agentStatus == "working")
    }

    @Test
    func decodesAgentList() throws {
        let result = try HerdrConnection.decode(agentListJSON, as: AgentListResult.self)
        #expect(result.agents.count == 3)

        let piAgent = try #require(result.agents.first { $0.agent == "pi" })
        #expect(piAgent.agentStatus == "working")
        #expect(piAgent.paneId == "w4H:p1")
        #expect(piAgent.tabId == "w4H:t1")
        #expect(piAgent.workspaceId == "w4H")
        #expect(piAgent.terminalTitleStripped == "π - herdrcat")
        #expect(piAgent.cwd == "/Users/demo/Projects/herdrcat")
        #expect(piAgent.focused == true)
    }

    @Test
    func decodesTabList() throws {
        let result = try HerdrConnection.decode(tabListJSON, as: TabListResult.self)
        #expect(result.tabs.count == 2)
        let tab = try #require(result.tabs.first { $0.tabId == "w4:tD" })
        #expect(tab.label == "1")
        #expect(tab.paneCount == 2)
        #expect(tab.agentStatus == "idle")
    }

    @Test
    func decodesPaneList() throws {
        let result = try HerdrConnection.decode(paneListJSON, as: PaneListResult.self)
        #expect(result.panes.count == 2)

        let agentPane = try #require(result.panes.first { $0.paneId == "w4:p2V" })
        #expect(agentPane.agent == "cursor")
        #expect(agentPane.tabId == "w4:tD")
        #expect(agentPane.label == "command")
        #expect(agentPane.displayTitle == "App Store Text")
        #expect(agentPane.status == .idle)
        #expect(agentPane.focused == true)
        #expect(agentPane.revision == nil)

        // A plain shell pane: no agent, no terminal title — falls back to the id.
        let shellPane = try #require(result.panes.first { $0.paneId == "w4:p33" })
        #expect(shellPane.agent == nil)
        #expect(shellPane.displayTitle == "w4:p33")
        #expect(shellPane.status == .unknown)
    }

    @Test
    func decodesPaneRevisionWhenPresent() throws {
        let json = """
        {"id":"cli:pane:list","result":{"panes":[
        {"agent":"cursor","agent_status":"idle","focused":true,"pane_id":"w4:p2V","revision":42,
        "tab_id":"w4:tD","workspace_id":"w4"}
        ]}}
        """
        let result = try HerdrConnection.decode(json, as: PaneListResult.self)
        #expect(result.panes.first?.revision == 42)
    }

    @Test
    func decodesPaneInfoResultAndHonorsCustomLabel() throws {
        let json = """
        {"id":"cli:pane:rename","result":{"pane":{"agent":"cursor","agent_status":"idle",
        "cwd":"/Users/demo/Projects/samplenotes","focused":true,"label":"Custom Pane Name",
        "pane_id":"w4:p2V","tab_id":"w4:tD","terminal_id":"term_65b95f43d22fa2",
        "terminal_title":"App Store Text","terminal_title_stripped":"App Store Text","workspace_id":"w4"},
        "type":"pane_info"}}
        """
        let result = try HerdrConnection.decode(json, as: PaneInfoResult.self)
        #expect(result.pane.paneId == "w4:p2V")
        #expect(result.pane.label == "Custom Pane Name")
        #expect(result.pane.displayTitle == "Custom Pane Name")
    }

    @Test
    func promotesErrorEnvelopes() {
        #expect(throws: HerdrError.self) {
            _ = try HerdrConnection.decode(errorJSON, as: WorkspaceListResult.self)
        }
    }
}

// MARK: - Workspace creation

@Suite("Workspace creation")
struct WorkspaceCreateTests {
    @Test
    func decodesCreatedWorkspaceWithTabAndRootPane() throws {
        let result = try HerdrConnection.decode(workspaceCreateJSON, as: WorkspaceCreateResult.self)
        #expect(result.workspace.workspaceId == "w50")
        #expect(result.workspace.label == "New Space")
        #expect(result.workspace.number == 10)
        #expect(result.tab?.tabId == "w50:t1")
        #expect(result.rootPane?.paneId == "w50:p1")
        #expect(result.rootPane?.cwd == "/Users/demo/Projects/herdrcat")
    }

    @Test
    func toleratesMissingTabAndRootPane() throws {
        let json = """
        {"id":"cli:workspace:create","result":{"workspace":{"active_tab_id":"w51:t1","agent_status":"idle",
        "focused":false,"label":"Bare","number":11,"pane_count":1,"tab_count":1,"workspace_id":"w51"}}}
        """
        let result = try HerdrConnection.decode(json, as: WorkspaceCreateResult.self)
        #expect(result.workspace.workspaceId == "w51")
        #expect(result.tab == nil)
        #expect(result.rootPane == nil)
    }

    @Test
    func commandOmitsEmptyCwdAndDefaultsToNoFocus() {
        #expect(HerdrConnection.workspaceCreateArguments(cwd: nil, focus: false)
                == "workspace create --no-focus")
        #expect(HerdrConnection.workspaceCreateArguments(cwd: "", focus: false)
                == "workspace create --no-focus")
    }

    @Test
    func commandQuotesCwdAndPassesFocus() {
        let cwd = "/Users/demo/My Projects/x; rm -rf /"
        #expect(
            HerdrConnection.workspaceCreateArguments(cwd: cwd, focus: true)
                == "workspace create --cwd \(HerdrConnection.shellSafeArgument(cwd)) --focus"
        )
    }

    @Test
    func markAgentSeenPrefersAgentFocusAndFallsBackToTab() {
        let pane = "w4:p2V;evil"
        let tab = "w4:tD`id`"
        #expect(
            HerdrConnection.markAgentSeenArguments(paneId: pane, tabId: tab, hasAgent: true)
                == "agent focus \(HerdrConnection.shellSafeArgument(pane))"
        )
        #expect(
            HerdrConnection.markAgentSeenArguments(paneId: pane, tabId: tab, hasAgent: false)
                == "tab focus \(HerdrConnection.shellSafeArgument(tab))"
        )
    }

    @Test
    func commandEscapesCwdWithShellMetacharacters() {
        let cwd = "/tmp/a; rm -rf / && echo `id` $HOME"
        let args = HerdrConnection.workspaceCreateArguments(cwd: cwd, focus: false)
        // Metacharacters never reach shell parsing — only printf octal escapes.
        #expect(!args.contains(";"))
        #expect(!args.contains("`"))
        #expect(!args.contains("$HOME"))
        #expect(!args.contains("'"))
    }
}

// MARK: - Workspace rename / close

@Suite("Workspace rename and close")
struct WorkspaceRenameCloseTests {
    @Test
    func decodesWorkspaceInfoResult() throws {
        let json = """
        {"id":"cli:workspace:rename","result":{"type":"workspace_info",
        "workspace":{"active_tab_id":"w4S:t1","agent_status":"unknown","focused":false,
        "label":"Renamed Space","number":15,"pane_count":1,"tab_count":1,"workspace_id":"w4S"}}}
        """
        let result = try HerdrConnection.decode(json, as: WorkspaceInfoResult.self)
        #expect(result.workspace.workspaceId == "w4S")
        #expect(result.workspace.label == "Renamed Space")
        #expect(result.workspace.number == 15)
    }

    @Test
    func decodesOkResultFromWorkspaceClose() throws {
        let json = """
        {"id":"cli:workspace:close","result":{"type":"ok"}}
        """
        _ = try HerdrConnection.decode(json, as: HerdrOkResult.self)
    }

    @Test
    func renameArgumentsEscapeWorkspaceIdAndLabel() {
        let label = "My Space; rm -rf /"
        let args = HerdrConnection.workspaceRenameArguments(workspaceId: "w4", label: label)
        #expect(args.hasPrefix("workspace rename "))
        #expect(args.contains(HerdrConnection.shellSafeArgument("w4")))
        #expect(args.contains(HerdrConnection.shellSafeArgument(label)))
        #expect(!args.contains(";"))
    }

    @Test
    func closeArgumentsEscapeWorkspaceId() {
        let args = HerdrConnection.workspaceCloseArguments(workspaceId: "w4;evil")
        #expect(
            args == "workspace close \(HerdrConnection.shellSafeArgument("w4;evil"))"
        )
        #expect(!args.contains(";evil"))
    }
}

// MARK: - Tab / pane list command construction

@Suite("Tab creation")
struct TabCreateTests {
    @Test func decodesRootPaneFromCreateResult() throws {
        let json = """
        {"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}
        """
        let result = try JSONDecoder().decode(TabCreateResult.self, from: Data(json.utf8))
        #expect(result.rootPane.paneId == "w1:p2")
    }

    @Test func commandEscapesUserProvidedArguments() {
        let workspace = "w1; $(touch /tmp/pwn)"
        let cwd = "/tmp/a' b`id`"
        let label = " New; $HOME `id` "
        let args = HerdrConnection.tabCreateArguments(
            workspaceId: workspace,
            cwd: cwd,
            label: label
        )
        #expect(args == "tab create --workspace \(HerdrConnection.shellSafeArgument(workspace))"
            + " --cwd \(HerdrConnection.shellSafeArgument(cwd))"
            + " --label \(HerdrConnection.shellSafeArgument("New; $HOME `id`")) --no-focus")
        #expect(!args.contains("$(touch"))
        #expect(!args.contains("`id`"))
    }

    @Test func emptyNameAndCwdUseHerdrDefaults() {
        #expect(HerdrConnection.tabCreateArguments(workspaceId: "w1", cwd: nil, label: "  ")
            == "tab create --workspace \(HerdrConnection.shellSafeArgument("w1")) --no-focus")
    }
}

@Suite("Tab and pane list commands")
struct TabPaneListCommandTests {
    @Test
    func listArgumentsQuoteNormalWorkspaceIds() {
        #expect(
            HerdrConnection.tabListArguments(workspaceId: "w4")
                == "tab list --workspace \(HerdrConnection.shellSafeArgument("w4"))"
        )
        #expect(
            HerdrConnection.paneListArguments(workspaceId: "w4H")
                == "pane list --workspace \(HerdrConnection.shellSafeArgument("w4H"))"
        )
    }

    @Test
    func listArgumentsEscapeShellMetacharactersInWorkspaceId() {
        let payloads = [
            "w4;evil",
            "w4; $(touch /tmp/pwn)",
            "w4`whoami`",
            "w4'\"quoted\"",
            "w4 with spaces",
            "w4\nnewline; id",
            "w4; rm -rf / && echo $HOME `id`"
        ]
        for workspaceId in payloads {
            let tabArgs = HerdrConnection.tabListArguments(workspaceId: workspaceId)
            let paneArgs = HerdrConnection.paneListArguments(workspaceId: workspaceId)
            #expect(
                tabArgs == "tab list --workspace \(HerdrConnection.shellSafeArgument(workspaceId))"
            )
            #expect(
                paneArgs == "pane list --workspace \(HerdrConnection.shellSafeArgument(workspaceId))"
            )
            // Metacharacters never reach shell parsing — only printf octal escapes.
            #expect(!tabArgs.contains(";"))
            #expect(!tabArgs.contains("`"))
            #expect(!tabArgs.contains("$HOME"))
            #expect(!tabArgs.contains("touch"))
            #expect(!tabArgs.contains("whoami"))
            #expect(!tabArgs.contains("'"))
            #expect(!tabArgs.contains("\n"))
            #expect(!paneArgs.contains(";"))
            #expect(!paneArgs.contains("`"))
            #expect(!paneArgs.contains("$HOME"))
            #expect(!paneArgs.contains("touch"))
            #expect(!paneArgs.contains("whoami"))
            #expect(!paneArgs.contains("'"))
            #expect(!paneArgs.contains("\n"))
        }
    }

    @Test
    func listArgumentsRemainEscapedWhenRoutedThroughMachineArguments() {
        let workspaceId = "w4; $(touch /tmp/unsafe); `whoami`\n'\" "
        let machineID = "mini'; $(id); `uname`\n"
        let tabRouted = HerdrConnection.machineArguments(
            HerdrConnection.tabListArguments(workspaceId: workspaceId),
            machineID: machineID
        )
        let paneRouted = HerdrConnection.machineArguments(
            HerdrConnection.paneListArguments(workspaceId: workspaceId),
            machineID: machineID
        )
        #expect(tabRouted.hasPrefix("--machine "))
        #expect(paneRouted.hasPrefix("--machine "))
        #expect(tabRouted.contains(HerdrConnection.tabListArguments(workspaceId: workspaceId)))
        #expect(paneRouted.contains(HerdrConnection.paneListArguments(workspaceId: workspaceId)))
        #expect(!tabRouted.contains("touch"))
        #expect(!tabRouted.contains("whoami"))
        #expect(!tabRouted.contains("uname"))
        #expect(!paneRouted.contains("touch"))
        #expect(!paneRouted.contains("whoami"))
        #expect(!paneRouted.contains("uname"))
        #expect(!tabRouted.contains("'"))
        #expect(!paneRouted.contains("'"))
    }
}

// MARK: - Worktree commands and decoding

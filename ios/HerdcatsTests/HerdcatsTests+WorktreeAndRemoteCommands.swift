import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Worktree commands and decoding")
struct WorktreeCommandTests {
    @Test
    func decodesWorktreeListResult() throws {
        let json = """
        {"id":"cli:worktree:list","result":{"source":{"repo_key":"/Users/demo/repo/.git",
        "repo_name":"repo","repo_root":"/Users/demo/repo","source_checkout_path":"/Users/demo/repo",
        "source_workspace_id":"w4"},"type":"worktree_list","worktrees":[{"branch":"main","is_bare":false,
        "is_detached":false,"is_linked_worktree":false,"is_prunable":false,"label":"repo",
        "open_workspace_id":"w4","path":"/Users/demo/repo"},{"branch":"feature/new-ui","is_bare":false,
        "is_detached":false,"is_linked_worktree":true,"is_prunable":false,"label":"repo",
        "path":"/Users/demo/.herdr/worktrees/repo/feature-new-ui"}]}}
        """
        let result = try HerdrConnection.decode(json, as: WorktreeListResult.self)
        #expect(result.source?.repoName == "repo")
        #expect(result.source?.sourceWorkspaceId == "w4")
        #expect(result.worktrees.count == 2)
        #expect(result.worktrees[0].branch == "main")
        #expect(result.worktrees[0].displayTitle == "main")
        #expect(result.worktrees[0].openWorkspaceId == "w4")
        #expect(result.worktrees[0].isLinkedWorktree == false)
        #expect(result.worktrees[1].displayTitle == "feature/new-ui")
        #expect(result.worktrees[1].openWorkspaceId == nil)
        #expect(result.worktrees[1].isLinkedWorktree == true)
    }

    @Test
    func decodesWorktreeOpenResult() throws {
        let json = """
        {"id":"cli:worktree:open","result":{"already_open":true,"root_pane":{"pane_id":"w36:p1",
        "tab_id":"w36:t1","workspace_id":"w36","agent_status":"idle","focused":false},
        "tab":{"tab_id":"w36:t1","workspace_id":"w36","label":"1","number":1,"pane_count":1,
        "agent_status":"idle","focused":false},"type":"worktree_opened","workspace":{"workspace_id":"w36",
        "label":"about","number":4,"tab_count":1,"pane_count":1,"active_tab_id":"w36:t1",
        "agent_status":"idle","focused":false,"worktree":{"checkout_path":"/Users/demo/worktree",
        "repo_name":"repo","repo_root":"/Users/demo/repo","is_linked_worktree":true}},
        "worktree":{"branch":"about","is_bare":false,"is_detached":false,"is_linked_worktree":true,
        "is_prunable":false,"label":"repo","open_workspace_id":"w36","path":"/Users/demo/worktree"}}}
        """
        let result = try HerdrConnection.decode(json, as: WorktreeOpenResult.self)
        #expect(result.alreadyOpen == true)
        #expect(result.workspace.workspaceId == "w36")
        #expect(result.worktree?.branch == "about")
        #expect(result.rootPane?.paneId == "w36:p1")
    }

    @Test
    func decodesWorktreeCreateResult() throws {
        let json = """
        {"id":"cli:worktree:create","result":{"root_pane":{"pane_id":"w4Q:p1","tab_id":"w4Q:t1",
        "workspace_id":"w4Q","agent_status":"unknown","focused":false},"tab":{"tab_id":"w4Q:t1",
        "workspace_id":"w4Q","label":"1","number":1,"pane_count":1,"agent_status":"unknown",
        "focused":false},"type":"worktree_created","workspace":{"workspace_id":"w4Q","label":"test-branch",
        "number":15,"tab_count":1,"pane_count":1,"active_tab_id":"w4Q:t1","agent_status":"unknown",
        "focused":false},"worktree":{"branch":"test-branch","is_bare":false,"is_detached":false,
        "is_linked_worktree":true,"is_prunable":false,"label":"repo","open_workspace_id":"w4Q",
        "path":"/Users/demo/worktree"}}}
        """
        let result = try HerdrConnection.decode(json, as: WorktreeCreateResult.self)
        #expect(result.workspace.workspaceId == "w4Q")
        #expect(result.worktree?.branch == "test-branch")
        #expect(result.rootPane?.paneId == "w4Q:p1")
    }

    @Test
    func worktreeListArgumentsHandlesWorkspaceAndCwd() {
        #expect(
            HerdrConnection.worktreeListArguments(workspaceId: "w4", cwd: nil)
                == "worktree list --workspace \(HerdrConnection.shellSafeArgument("w4"))"
        )
        #expect(
            HerdrConnection.worktreeListArguments(workspaceId: nil, cwd: "/path/to/repo")
                == "worktree list --cwd \(HerdrConnection.shellSafeArgument("/path/to/repo"))"
        )
        #expect(
            HerdrConnection.worktreeListArguments(workspaceId: nil, cwd: nil)
                == "worktree list"
        )
    }

    @Test
    func worktreeOpenArgumentsEscapesInputsAndAppliesFlags() {
        let path = "/Users/demo/work tree/feat;rm"
        let branch = "feat/test; `echo hi`"
        let args = HerdrConnection.worktreeOpenArguments(WorktreeOpenCommand(
            workspaceId: "w4",
            cwd: nil,
            path: path,
            branch: branch,
            label: "My Label",
            focus: true
        ))
        #expect(args.contains("worktree open"))
        #expect(args.contains("--workspace \(HerdrConnection.shellSafeArgument("w4"))"))
        #expect(args.contains("--path \(HerdrConnection.shellSafeArgument(path))"))
        #expect(args.contains("--branch \(HerdrConnection.shellSafeArgument(branch))"))
        #expect(args.contains("--label \(HerdrConnection.shellSafeArgument("My Label"))"))
        #expect(args.contains("--focus"))
        #expect(!args.contains(";rm"))
        #expect(!args.contains("`"))
    }

    @Test
    func worktreeCreateArgumentsEscapesInputsAndAppliesFlags() {
        let branch = "feature/awesome; $(id)"
        let base = "origin/main & touch /tmp/pwn"
        let args = HerdrConnection.worktreeCreateArguments(WorktreeCreateCommand(
            workspaceId: "w10",
            cwd: nil,
            branch: branch,
            base: base,
            path: nil,
            label: "Awesome",
            focus: false
        ))
        #expect(args.contains("worktree create"))
        #expect(args.contains("--workspace \(HerdrConnection.shellSafeArgument("w10"))"))
        #expect(args.contains("--branch \(HerdrConnection.shellSafeArgument(branch))"))
        #expect(args.contains("--base \(HerdrConnection.shellSafeArgument(base))"))
        #expect(args.contains("--label \(HerdrConnection.shellSafeArgument("Awesome"))"))
        #expect(args.contains("--no-focus"))
        #expect(!args.contains("$(id)"))
        #expect(!args.contains("& touch"))
    }

    @Test
    func decodesOkResultFromWorktreeRemove() throws {
        let json = """
        {"id":"cli:worktree:remove","result":{"type":"worktree_removed","workspace_id":"w10","forced":false}}
        """
        _ = try HerdrConnection.decode(json, as: HerdrOkResult.self)
    }

    @Test
    func worktreeRemoveArgumentsEscapeWorkspaceIdAndApplyFlags() {
        let args = HerdrConnection.worktreeRemoveArguments(
            workspaceId: "w10; rm -rf /",
            force: true,
            trustRepository: true
        )
        #expect(
            args == "worktree remove --workspace \(HerdrConnection.shellSafeArgument("w10; rm -rf /"))"
                + " --force --trust-repository"
        )
        #expect(!args.contains("; rm"))

        let plain = HerdrConnection.worktreeRemoveArguments(
            workspaceId: "w10",
            force: false,
            trustRepository: false
        )
        #expect(plain == "worktree remove --workspace \(HerdrConnection.shellSafeArgument("w10"))")
        #expect(!plain.contains("--force"))
        #expect(!plain.contains("--trust-repository"))
    }
}

// MARK: - Worktree name validation and default space

@Suite("Worktree name validation and default space")
struct WorktreeValidationAndDefaultSpaceTests {
    @Test
    func emptyNameIsValidBecauseHerdrGeneratesDefault() {
        #expect(WorktreeNameValidator.validate("") == nil)
    }

    @Test
    func validNamesPassValidation() {
        let validCases = [
            "feature",
            "feature-1",
            "feature/new-ui",
            "fix_issue",
            "v1.2.3",
            "user@domain",
            "branch#123"
        ]
        for name in validCases {
            #expect(WorktreeNameValidator.validate(name) == nil, "Expected \(name) to be valid")
        }
    }

    @Test
    func spaceContainingNamesAreRejected() {
        let spaceCases = [
            "my feature",
            " feature",
            "feature ",
            "   ",
            "feature\tbranch",
            "feature\nbranch"
        ]
        for name in spaceCases {
            #expect(
                WorktreeNameValidator.validate(name) == "Worktree name cannot contain spaces",
                "Expected \(name) to fail with spaces error"
            )
        }
    }

    @Test
    func invalidCharactersAndStructuralRulesAreRejected() {
        #expect(WorktreeNameValidator.validate("-feature") == "Worktree name cannot start with a hyphen")
        #expect(WorktreeNameValidator.validate("/feature") == "Worktree name cannot start or end with a slash")
        #expect(WorktreeNameValidator.validate("feature/") == "Worktree name cannot start or end with a slash")
        #expect(WorktreeNameValidator.validate("feature//branch") == "Worktree name cannot contain consecutive slashes")
        #expect(WorktreeNameValidator.validate("feature.") == "Worktree name cannot end with a period")
        #expect(WorktreeNameValidator.validate("feature.lock") == "Worktree name cannot end with '.lock'")
        #expect(WorktreeNameValidator.validate("feature..branch") == "Worktree name cannot contain '..'")
        #expect(WorktreeNameValidator.validate("feature@{branch") == "Worktree name cannot contain '@{'")
        #expect(WorktreeNameValidator.validate("@") == "Worktree name cannot be '@'")

        #expect(WorktreeNameValidator.validate("feature~1") == "Worktree name cannot contain '~'")
        #expect(WorktreeNameValidator.validate("feature^1") == "Worktree name cannot contain '^'")
        #expect(WorktreeNameValidator.validate("feature:branch") == "Worktree name cannot contain ':'")
        #expect(WorktreeNameValidator.validate("feature?branch") == "Worktree name cannot contain '?'")
        #expect(WorktreeNameValidator.validate("feature*branch") == "Worktree name cannot contain '*'")
        #expect(WorktreeNameValidator.validate("feature[branch") == "Worktree name cannot contain '['")
        #expect(WorktreeNameValidator.validate("feature\\branch") == "Worktree name cannot contain '\\'")
        #expect(WorktreeNameValidator.validate("feature\"branch") == "Worktree name cannot contain '\"'")
        #expect(WorktreeNameValidator.validate("feature'branch") == "Worktree name cannot contain '\''")
    }

    @Test
    @MainActor
    func defaultSpaceResolvesRootWorktreeForLinkedWorktree() throws {
        let workspaces = try HerdrConnection.decode(
            workspaceListWithWorktreesJSON,
            as: WorkspaceListResult.self
        ).workspaces
        let spaces = Space.join(workspaces: workspaces, agents: [])
        let model = SpacesModel()

        let linkedShare = try #require(spaces.first { $0.id == "w3W" })
        let rootSampleshop = try #require(spaces.first { $0.id == "w35" })
        let standaloneSamplemedia = try #require(spaces.first { $0.id == "w32" })
        let orphanAlpha = try #require(spaces.first { $0.id == "w4C" })

        // Calling on linked worktree returns root workspace of the repo:
        #expect(model.defaultSpace(for: linkedShare, in: spaces).id == rootSampleshop.id)
        // Calling on root workspace returns itself:
        #expect(model.defaultSpace(for: rootSampleshop, in: spaces).id == rootSampleshop.id)
        // Calling on standalone space without worktree returns itself:
        #expect(model.defaultSpace(for: standaloneSamplemedia, in: spaces).id == standaloneSamplemedia.id)
        // Calling on orphan linked worktree with no root workspace returns itself:
        #expect(model.defaultSpace(for: orphanAlpha, in: spaces).id == orphanAlpha.id)
    }
}

// MARK: - Interpretation of wrapper output

@Suite("Remote command wrapper")
struct RemoteCommandTests {
    @Test
    func herdrTimeoutUsesContentFreeDiagnosticLabel() async throws {
        let secret = "synthetic-pane-secret-9281"
        let label = HerdrConnection.herdrDiagnosticLabel
        #expect(label == "herdr command")

        var thrown: Error?
        do {
            _ = try await withTimeout(seconds: 0.01, label: label) {
                try await Task.sleep(for: .seconds(1))
                return 0
            }
        } catch {
            thrown = error
        }
        #expect(thrown as? HerdrError == .timeout("herdr command"))
        #expect(thrown?.localizedDescription.contains(secret) == false)
    }

    @Test
    func wrapperResolvesHerdrAndAvoidsSingleQuotes() {
        let command = HerdrConnection.remoteCommand("workspace list")
        #expect(command.hasPrefix("exec sh -c '"))
        #expect(command.hasSuffix("'"))
        // The inner script must not contain single quotes.
        let inner = command.dropFirst("exec sh -c '".count).dropLast()
        #expect(!inner.contains("'"))
        #expect(inner.contains("command -v herdr"))
        #expect(inner.contains(".local/bin/herdr"))
        #expect(inner.contains("workspace list"))
    }

    @Test
    func shellSafeArgumentEscapesArbitraryText() {
        let nasty = "it's a \"test\" with $HOME, `backticks`, ; rm -rf /, and\na newline"
        let arg = HerdrConnection.shellSafeArgument(nasty)

        // The single invariant that keeps the outer `sh -c '...'` intact.
        #expect(!arg.contains("'"))
        // Only printf-safe characters between the double quotes.
        let octalPart = arg.dropFirst("\"$(printf \"".count).dropLast(3)
        #expect(!octalPart.isEmpty)
        #expect(octalPart.allSatisfy { $0.isNumber || $0 == "\\" })

        // Round-trip: reconstructing the octal bytes yields the original text.
        let bytes = octalPart
            .split(separator: "\\")
            .compactMap { UInt8($0, radix: 8) }
        #expect(String(bytes: bytes, encoding: .utf8) == nasty)
    }

    @Test
    func shellSafeArgumentHandlesPlainTextAndEmpty() {
        #expect(
            HerdrConnection.shellSafeArgument("hello pane")
                == "\"$(printf \"\\150\\145\\154\\154\\157\\040\\160\\141\\156\\145\")\""
        )
        // Empty input still produces valid shell: an empty argument.
        #expect(
            HerdrConnection.shellSafeArgument("")
                == "\"$(printf \"\")\""
        )
    }

    @Test
    func imagePromptIncludesPathAndOptionalMessage() {
        #expect(
            HerdrConnection.imagePrompt(remotePath: "/tmp/a.png", userMessage: "")
                == "Please open and inspect this image: /tmp/a.png"
        )
        #expect(
            HerdrConnection.imagePrompt(remotePath: "/tmp/a.png", userMessage: "  what is this?  ")
                == "Please open and inspect this image: /tmp/a.png\n\nwhat is this?"
        )
    }

    @Test
    func sanitizedAttachmentExtensionNormalizesCommonTypes() {
        #expect(HerdrConnection.sanitizedAttachmentExtension("JPEG") == "jpg")
        #expect(HerdrConnection.sanitizedAttachmentExtension("png") == "png")
        #expect(HerdrConnection.sanitizedAttachmentExtension("../x") == "jpg")
    }

    @Test
    func passesThroughPlainOutput() throws {
        let output = try HerdrConnection.interpret("{\"id\":\"x\",\"result\":{}}\n")
        #expect(output == "{\"id\":\"x\",\"result\":{}}")
    }

    @Test
    func detectsMissingHerdr() {
        #expect(throws: HerdrError.herdrNotFound) {
            _ = try HerdrConnection.interpret("HERDRCAT_HERDR_NOT_FOUND\n")
        }
    }

    @Test
    func extractsAPIErrorFromExitOutput() {
        let output = "HERDRCAT_EXIT_1\n" + errorJSON
        #expect(throws: HerdrError.self) {
            _ = try HerdrConnection.interpret(output)
        }
    }

    @Test
    func rejectsEmptyOutput() {
        #expect(throws: HerdrError.self) {
            _ = try HerdrConnection.interpret("  \n")
        }
    }
}

// MARK: - Space aggregation

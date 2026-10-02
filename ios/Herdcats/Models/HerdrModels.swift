import Foundation

/// `machine list --json` returns a bare array, unlike socket API envelopes.
struct HerdrMachine: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
}

// MARK: - Response envelope

/// Every `herdr` CLI command responds with a single-line JSON envelope that
/// contains either a `result` payload or an `error` object.
struct HerdrEnvelope<Result: Decodable>: Decodable {
    let id: String?
    let result: Result?
    let error: HerdrAPIError?
}

struct HerdrAPIError: Decodable, Error, Hashable {
    let code: String
    let message: String
}

// MARK: - `herdr workspace list`

struct WorkspaceListResult: Decodable {
    let workspaces: [Workspace]
}

struct Workspace: Decodable, Hashable, Identifiable {
    let workspaceId: String
    let label: String
    let number: Int
    let tabCount: Int
    let paneCount: Int
    let activeTabId: String
    let agentStatus: String
    let focused: Bool
    let worktree: Worktree?

    var id: String { workspaceId }

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case label
        case number
        case tabCount = "tab_count"
        case paneCount = "pane_count"
        case activeTabId = "active_tab_id"
        case agentStatus = "agent_status"
        case focused
        case worktree
    }
}

struct Worktree: Decodable, Hashable {
    let checkoutPath: String
    let repoName: String
    let repoRoot: String
    let isLinkedWorktree: Bool

    enum CodingKeys: String, CodingKey {
        case checkoutPath = "checkout_path"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
        case isLinkedWorktree = "is_linked_worktree"
    }
}

// MARK: - `herdr agent list`

struct AgentListResult: Decodable {
    let agents: [AgentEntry]
}

struct AgentEntry: Decodable, Hashable, Identifiable {
    let agent: String
    let agentStatus: String
    /// Server ordering of lifecycle changes, not a completion timestamp.
    let stateChangeSeq: UInt64?
    let cwd: String?
    let paneId: String
    let tabId: String
    let workspaceId: String
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let focused: Bool
    /// Monotonic Herdr pane revision; bumps when pane state changes.
    let revision: UInt64?

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus = "agent_status"
        case stateChangeSeq = "state_change_seq"
        case cwd
        case paneId = "pane_id"
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case focused
        case revision
    }

    /// Human-readable row title — the stripped terminal title when present.
    var displayTitle: String {
        if let stripped = terminalTitleStripped, !stripped.isEmpty {
            return stripped
        }
        return paneId
    }

    /// Compact `~/last/two/components` form of the working directory.
    var shortCwd: String {
        guard let cwd else { return "" }
        let suffix = cwd.split(separator: "/").suffix(2).joined(separator: "/")
        return suffix.isEmpty ? cwd : "~/\(suffix)"
    }
}

// MARK: - `herdr tab list --workspace <id>`

struct TabListResult: Decodable {
    let tabs: [TabEntry]
}

// MARK: - `herdr tab create`

struct TabCreateResult: Decodable {
    let rootPane: CreatedPaneReference

    enum CodingKeys: String, CodingKey {
        case rootPane = "root_pane"
    }
}

struct CreatedPaneReference: Decodable {
    let paneId: String

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
    }
}

struct TabEntry: Decodable, Hashable, Identifiable {
    let tabId: String
    let workspaceId: String
    let label: String
    let number: Int
    let paneCount: Int
    let agentStatus: String
    let focused: Bool

    var id: String { tabId }

    enum CodingKeys: String, CodingKey {
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case label
        case number
        case paneCount = "pane_count"
        case agentStatus = "agent_status"
        case focused
    }
}

// MARK: - `herdr pane list --workspace <id>`

struct PaneListResult: Decodable {
    let panes: [PaneEntry]
}

struct PaneEntry: Decodable, Hashable, Identifiable {
    let paneId: String
    let tabId: String
    let workspaceId: String
    let label: String?
    let agent: String?
    let agentStatus: String
    let cwd: String?
    let terminalTitle: String?
    let terminalTitleStripped: String?
    let focused: Bool
    /// Monotonic Herdr pane revision; bumps when pane state changes.
    let revision: UInt64?

    var id: String { paneId }

    enum CodingKeys: String, CodingKey {
        case paneId = "pane_id"
        case tabId = "tab_id"
        case workspaceId = "workspace_id"
        case label
        case agent
        case agentStatus = "agent_status"
        case cwd
        case terminalTitle = "terminal_title"
        case terminalTitleStripped = "terminal_title_stripped"
        case focused
        case revision
    }

    var status: AgentStatus {
        AgentStatus(rawValue: agentStatus) ?? .unknown
    }

    /// Row title: custom pane label (if set and not default "command"),
    /// else stripped terminal title, else label, else pane id.
    var displayTitle: String {
        if let label, !label.isEmpty, label != "command" {
            return label
        }
        if let stripped = terminalTitleStripped, !stripped.isEmpty {
            return stripped
        }
        if let label, !label.isEmpty {
            return label
        }
        return paneId
    }

    /// Compact `~/last/two/components` form of the working directory.
    var shortCwd: String {
        guard let cwd else { return "" }
        let suffix = cwd.split(separator: "/").suffix(2).joined(separator: "/")
        return suffix.isEmpty ? cwd : "~/\(suffix)"
    }
}

// MARK: - `herdr pane rename` / `herdr pane split`

struct PaneInfoResult: Decodable {
    let pane: PaneEntry
}

// MARK: - `herdr workspace create`

struct WorkspaceCreateResult: Decodable {
    let workspace: Workspace
    /// The initial tab and root pane herdr opened in the new workspace.
    /// Optional because the envelope shape varies by herdr version.
    let tab: TabEntry?
    let rootPane: PaneEntry?

    enum CodingKeys: String, CodingKey {
        case workspace
        case tab
        case rootPane = "root_pane"
    }
}

// MARK: - `herdr workspace rename` / `herdr workspace get`

struct WorkspaceInfoResult: Decodable {
    let workspace: Workspace
}

/// Envelope for commands that return `{ "type": "ok" }` (e.g. `workspace close`).
struct HerdrOkResult: Decodable {}

// MARK: - `herdr worktree list`

struct WorktreeListResult: Decodable, Sendable {
    let source: WorktreeSource?
    let worktrees: [WorktreeEntry]

    enum CodingKeys: String, CodingKey {
        case source
        case worktrees
    }
}

struct WorktreeSource: Decodable, Hashable, Sendable {
    let repoKey: String?
    let repoName: String?
    let repoRoot: String?
    let sourceCheckoutPath: String?
    let sourceWorkspaceId: String?

    enum CodingKeys: String, CodingKey {
        case repoKey = "repo_key"
        case repoName = "repo_name"
        case repoRoot = "repo_root"
        case sourceCheckoutPath = "source_checkout_path"
        case sourceWorkspaceId = "source_workspace_id"
    }
}

struct WorktreeEntry: Decodable, Hashable, Identifiable, Sendable {
    let path: String
    let branch: String?
    let label: String?
    let isBare: Bool?
    let isDetached: Bool?
    let isLinkedWorktree: Bool?
    let isPrunable: Bool?
    let openWorkspaceId: String?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case branch
        case label
        case isBare = "is_bare"
        case isDetached = "is_detached"
        case isLinkedWorktree = "is_linked_worktree"
        case isPrunable = "is_prunable"
        case openWorkspaceId = "open_workspace_id"
    }

    var displayTitle: String {
        if let branch, !branch.isEmpty {
            return branch
        }
        if let label, !label.isEmpty {
            return label
        }
        return (path as NSString).lastPathComponent
    }
}

// MARK: - `herdr worktree open`

struct WorktreeOpenResult: Decodable, Sendable {
    let workspace: Workspace
    let alreadyOpen: Bool?
    let worktree: WorktreeEntry?
    let tab: TabEntry?
    let rootPane: PaneEntry?

    enum CodingKeys: String, CodingKey {
        case workspace
        case alreadyOpen = "already_open"
        case worktree
        case tab
        case rootPane = "root_pane"
    }
}

// MARK: - `herdr worktree create`

struct WorktreeCreateResult: Decodable, Sendable {
    let workspace: Workspace
    let worktree: WorktreeEntry?
    let tab: TabEntry?
    let rootPane: PaneEntry?

    enum CodingKeys: String, CodingKey {
        case workspace
        case worktree
        case tab
        case rootPane = "root_pane"
    }
}

// MARK: - Worktree name validation

struct WorktreeNameValidator {
    /// Validates a candidate worktree name according to Git ref and naming rules.
    /// Returns an error message if invalid, or `nil` if valid.
    /// An empty string is considered valid because Herdr automatically generates a default name.
    static func validate(_ name: String) -> String? {
        if name.isEmpty {
            return nil
        }
        if name.contains(where: { $0.isWhitespace }) {
            return "Worktree name cannot contain spaces"
        }
        if name.hasPrefix("-") {
            return "Worktree name cannot start with a hyphen"
        }
        if name.hasPrefix("/") || name.hasSuffix("/") {
            return "Worktree name cannot start or end with a slash"
        }
        if name.contains("//") {
            return "Worktree name cannot contain consecutive slashes"
        }
        if name.hasSuffix(".") {
            return "Worktree name cannot end with a period"
        }
        if name.hasSuffix(".lock") {
            return "Worktree name cannot end with '.lock'"
        }
        if name.contains("..") {
            return "Worktree name cannot contain '..'"
        }
        if name.contains("@{") {
            return "Worktree name cannot contain '@{'"
        }
        if name == "@" {
            return "Worktree name cannot be '@'"
        }

        let forbidden = CharacterSet(charactersIn: "~^:?*[\\]\"'`")
            .union(.controlCharacters)

        if let range = name.rangeOfCharacter(from: forbidden) {
            let char = name[range]
            if let first = char.first, first.isASCII && !first.isWhitespace {
                return "Worktree name cannot contain '\(first)'"
            } else {
                return "Worktree name contains unsupported characters"
            }
        }

        return nil
    }
}

// MARK: - Status

enum AgentStatus: String, Hashable {
    case idle
    case working
    case blocked
    case done
    case unknown

    /// Herdr's attention priority: a higher value is more attention-worthy.
    /// Mirrors `tab_attention_priority` (herdr `src/app/api_helpers.rs`) and
    /// the identical `status_priority` (`src/client/shell.rs`): blocked needs
    /// input now, done is idle work nobody has seen yet, and unknown claims
    /// the least attention. Keep this in sync with herdr, not local
    /// preference — the server owns this state machine.
    var attentionPriority: Int {
        switch self {
        case .blocked: 4
        case .done: 3
        case .working: 2
        case .idle: 1
        case .unknown: 0
        }
    }

    var label: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .blocked: "Blocked"
        case .done: "Done"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Joined view model

/// A workspace joined with the agents that live inside it — the unit the UI renders.
struct SpaceMachine: Identifiable, Hashable {
    let scope: ConnectionIdentity
    let label: String
    let order: Int
    var id: String { scope.storageKey }
}

struct Space: Identifiable, Hashable {
    let workspace: Workspace
    let agents: [AgentEntry]
    var machine: SpaceMachine? = nil

    var id: String {
        guard let machine else { return workspace.workspaceId }
        return machine.id + "|w=" + ConnectionIdentity.encodeComponent(workspace.workspaceId)
    }

    var label: String {
        workspace.label.isEmpty ? workspace.workspaceId : workspace.label
    }

    /// The most interesting status across the space's agents, falling back to
    /// the workspace-level status herdr already aggregates.
    var status: AgentStatus {
        let agentStatuses = agents.compactMap { AgentStatus(rawValue: $0.agentStatus) }
        if let top = agentStatuses.max(by: { $0.attentionPriority < $1.attentionPriority }) {
            return top
        }
        return AgentStatus(rawValue: workspace.agentStatus) ?? .unknown
    }

    static func join(workspaces: [Workspace], agents: [AgentEntry]) -> [Space] {
        let agentsByWorkspace = Dictionary(grouping: agents, by: \.workspaceId)
        return workspaces
            .map { workspace in
                Space(
                    workspace: workspace,
                    agents: (agentsByWorkspace[workspace.workspaceId] ?? []).sorted {
                        ($0.terminalTitleStripped ?? $0.paneId) < ($1.terminalTitleStripped ?? $1.paneId)
                    }
                )
            }
            .sorted { $0.workspace.number < $1.workspace.number }
    }
}

// MARK: - Grouped view model

/// A root space card plus the linked-worktree spaces folded underneath it.
/// Spaces that share a repository root collapse into one card: the checkout
/// at the repo root becomes the card, and each linked worktree renders as a
/// sub-row with its own status. Spaces without a worktree stay standalone.
struct SpaceGroup: Identifiable, Hashable {
    let root: Space
    let worktrees: [Space]

    var id: String { root.id }

    /// All spaces in the group, root first, then worktrees by number.
    var members: [Space] {
        [root] + worktrees
    }

    /// The most attention-worthy status across the root and its worktrees.
    var status: AgentStatus {
        ([root] + worktrees)
            .map(\.status)
            .max { $0.attentionPriority < $1.attentionPriority }
            ?? root.status
    }

    var isFocused: Bool {
        ([root] + worktrees).contains { $0.workspace.focused }
    }

    /// Herdr's attention ordering applied to a whole space group: the group
    /// status first, then the latest lifecycle change across its agents, with
    /// workspace order as the deterministic fallback.
    static func attentionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.status.attentionPriority != rhs.status.attentionPriority {
            return lhs.status.attentionPriority > rhs.status.attentionPriority
        }

        if lhs.root.machine?.id != rhs.root.machine?.id {
            return (lhs.root.machine?.order ?? 0, lhs.root.machine?.id ?? "")
                < (rhs.root.machine?.order ?? 0, rhs.root.machine?.id ?? "")
        }
        switch (lhs.latestStateChangeSeq, rhs.latestStateChangeSeq) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }

        return (lhs.root.workspace.number, lhs.root.label, lhs.id)
            < (rhs.root.workspace.number, rhs.root.label, rhs.id)
    }

    private var latestStateChangeSeq: UInt64? {
        members.flatMap { $0.agents.compactMap(\.stateChangeSeq) }.max()
    }

    static func group(_ spaces: [Space]) -> [SpaceGroup] {
        var byRepo: [String: [Space]] = [:]
        var standalone: [SpaceGroup] = []

        for space in spaces {
            if let repoRoot = space.workspace.worktree?.repoRoot, !repoRoot.isEmpty {
                let key = (space.machine?.id ?? "") + "|repo=" + ConnectionIdentity.encodeComponent(repoRoot)
                byRepo[key, default: []].append(space)
            } else {
                standalone.append(SpaceGroup(root: space, worktrees: []))
            }
        }

        var grouped: [SpaceGroup] = []
        for members in byRepo.values {
            let sorted = members.sorted { $0.workspace.number < $1.workspace.number }
            // The non-linked checkout is the card; linked worktrees fold under it.
            guard let root = sorted.first(where: { $0.workspace.worktree?.isLinkedWorktree != true }) else {
                // No root-worktree workspace exists for this repo — promote the
                // first linked worktree to the card so the group stays visible.
                grouped.append(SpaceGroup(root: sorted[0], worktrees: Array(sorted.dropFirst())))
                continue
            }
            grouped.append(SpaceGroup(root: root, worktrees: sorted.filter { $0.id != root.id }))
        }

        return (grouped + standalone).sorted {
            ($0.root.machine?.order ?? 0, $0.root.workspace.number, $0.id)
                < ($1.root.machine?.order ?? 0, $1.root.workspace.number, $1.id)
        }
    }
}

import Foundation
import Observation
import SwiftUI

// MARK: - Spaces model

@MainActor
@Observable
final class SpacesModel {
    private(set) var spaces: [Space] = [] {
        didSet {
            spaceGroups = SpaceGroup.group(spaces)
        }
    }
    private(set) var spaceGroups: [SpaceGroup] = []
    /// Latest pane activity among the space's agents — the list row's timestamp.
    func lastActivity(in space: Space) -> Date? {
        let dates = lastUpdatedByPaneID
        return space.agents.compactMap { dates[$0.paneId] }.max()
    }

    private(set) var lastUpdated: Date?
    /// Pane-id → last activity time, shared with pane detail cards.
    private(set) var lastUpdatedByPaneID: [String: Date] = [:]
    // The view can render before its initial refresh task starts.
    private(set) var isLoading = true

    /// A successful refresh confirms the agent list, even when it is empty.
    var hasLoadedAgentList: Bool {
        return lastUpdated != nil
    }
    /// Provider usage cards for the Agents header (from remote `quota-axi`).
    var usageCards: [AgentUsageCard] = []
    var usageLastUpdated: Date?
    var usageUnavailableMessage: String?
    /// True when the Herdr machine has no `quota-axi` binary to query.
    var quotaAxiMissing = false
    /// quota-axi provider ids with a card retry in flight.
    var retryingUsageProviders: Set<String> = []

    var errorMessage: String?

    /// Initial failures must expose Retry instead of looking like an endless load.
    var agentListError: String? {
        guard let errorMessage,
              !HerdrConnection.isDisconnectionOrTransitionMessage(errorMessage) else { return nil }
        return errorMessage
    }

    var showsAgentLoading: Bool {
        isLoading || (!hasLoadedAgentList && agentListError == nil)
    }
    var autoRefreshEnabled = true
    /// When false, periodic polls sleep without issuing remote commands.
    /// Initial / pull-to-refresh loads still run.
    var isSceneActive = true
    private(set) var isCreatingSpace = false
    private(set) var pendingSpaceCreationTitle: String?
    private(set) var lastPresentedSpaceID: String?
    private(set) var unconfirmedSpaces: [Space] = []
    private(set) var pendingWorktreeAction: PendingWorktreeAction?
    private(set) var highlightedWorktreeID: String?

    var visibleSpaceGroups: [SpaceGroup] {
        guard !unconfirmedSpaces.isEmpty else { return spaceGroups }
        return SpaceGroup.group(SpacePresentationOverlay.visibleSpaces(spaces, unconfirmed: unconfirmedSpaces))
    }

    /// Attention badge for the Agents tab — hidden while zero.
    var blockedAgentCount: Int {
        spaces.flatMap(\.agents).filter { AgentStatus(rawValue: $0.agentStatus) == .blocked }.count
    }

    var autoRefreshTask: Task<Void, Never>?
    /// Counts started refreshes so the auto-refresh loop can restart its
    /// interval after an event-driven or manual refresh.
    @ObservationIgnored var refreshEpoch = 0
    var usageRefreshTask: Task<Void, Never>?
    enum QuotaContentState: Equatable {
        case loading, cards, notSetup, empty
        case error(String)
    }
    var hasCompletedUsageRequest = false
    var quotaContentState: QuotaContentState {
        if !usageCards.isEmpty { return .cards }
        if quotaAxiMissing { return .notSetup }
        if isRefreshingUsage { return .loading }
        if let message = usageUnavailableMessage { return .error(message) }
        if usageLastUpdated != nil || hasCompletedUsageRequest { return .empty }
        return .loading // Initial view mounts before its fetch task starts.
    }
    var isRefreshingUsage = false
    @ObservationIgnored var quotaRetryFetch: ((String) async throws -> QuotaReport)?
    @ObservationIgnored var quotaReportFetch: (() async throws -> QuotaReport)?
    @ObservationIgnored var agentListFetch: (() async throws -> ([Workspace], [AgentEntry]))?
    private var refreshGate = RefreshGenerationGate()
    @ObservationIgnored private var tabEnrichment: (
        id: UInt64, connection: HerdrConnection, source: ConnectionGeneration,
        retained: [String: ContinuousClock.Instant], task: Task<Void, Never>
    )?
    @ObservationIgnored private var verifiedTabSource: (HerdrConnection, ConnectionGeneration)?
    private enum ObservedTabSource {
        case unobserved
        case generation(ConnectionGeneration?)
    }
    @ObservationIgnored private var observedTabSource = ObservedTabSource.unobserved
    var usageGate = RefreshGenerationGate()
    private var connectionScope: ConnectionIdentity?
    private var spaceCreationGeneration = 0
    private var worktreeActionGeneration = 0
    /// Agent statuses from the last successful refresh; `nil` until the first
    /// load so connecting never replays existing done / blocked states.
    private var alertBaseline: [String: AgentStatus]?
    /// Test seam: plays the user's chosen sound and haptic for an agent alert.
    var playAlert: (AgentAlertEvent) -> Void = { event in
        AgentAlertSound.selected(for: event).play()
        HapticFeedback.play(for: event)
    }

    func bindConnectionScope(_ scope: ConnectionIdentity?) {
        if connectionScope != scope {
            tabEnrichment?.task.cancel()
            clearVerifiedTabLabels()
            spaceCreationGeneration += 1
            isCreatingSpace = false
            pendingSpaceCreationTitle = nil
            lastPresentedSpaceID = nil
            unconfirmedSpaces = []
            worktreeActionGeneration += 1
            isPerformingWorktreeAction = false
            pendingWorktreeAction = nil
            highlightedWorktreeID = nil
        }
        connectionScope = scope
        alertBaseline = nil
        if let scope {
            lastUpdatedByPaneID = PaneLastUpdatedStore.dates(scope: scope)
        } else {
            lastUpdatedByPaneID = [:]
        }
    }

    func refresh(
        _ connection: HerdrConnection,
        deadline: ContinuousClock.Instant = .now + .seconds(45),
        isPoll: Bool = false
    ) async {
        let generation = refreshGate.begin()
        let initialScope = connectionScope
        refreshEpoch &+= 1
        isLoading = true

        // Watchdog: invalidate this generation so a late completion cannot
        // overwrite a newer refresh, then unlock the UI.
        let watchdog = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
            guard let self else { return }
            guard self.refreshGate.watchdogTimeout(for: generation) else { return }
            self.isLoading = false
            self.errorMessage = "Refreshing timed out — the connection may be unhealthy."
        }
        defer {
            watchdog.cancel()
            if refreshGate.finishIfCurrent(generation) {
                isLoading = false
            }
        }

        do {
            let workspaceList: [Workspace]
            let agentList: [AgentEntry]
            let source: ConnectionGeneration?
            let backend: ConnectionBackend?
            if let agentListFetch {
                (workspaceList, agentList) = try await agentListFetch()
                source = nil
                backend = nil
            } else {
                (workspaceList, agentList, source, backend) = try await connection.spaceOverview()
            }
            let scope: ConnectionIdentity? = if let initialScope { initialScope } else { await connection.identity }
            if let source, await connection.generation != source { return }
            guard refreshGate.isCurrent(generation), connectionScope == initialScope, !Task.isCancelled else { return }
            if backend == .tui, let source, !canPublishTabLabels(from: source) { return }
            if let pending = tabEnrichment,
               !isPoll || pending.connection !== connection || pending.source != source {
                pending.task.cancel()
            }
            let occupied = Set(agentList.map(\.workspaceId))
            let tabWorkspaceIDs = Set(backend == .tui ? workspaceList.filter {
                occupied.contains($0.workspaceId) && $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.map(\.workspaceId) : [])
            let reusesEnrichment = isPoll && tabEnrichment?.task.isCancelled == false
            var retained: [String: ContinuousClock.Instant] = [:]
            var baseAgents = agentList
            if let source, verifiedTabSource?.0 === connection, verifiedTabSource?.1 == source,
               !tabWorkspaceIDs.isEmpty {
                var labels: [String: [String: String]] = [:]
                let now = ContinuousClock.now
                for space in spaces where tabWorkspaceIDs.contains(space.id) {
                    if let cutoff = tabEnrichment?.retained[space.id], cutoff <= now { continue }
                    for agent in space.agents {
                        labels[space.id, default: [:]][agent.tabId] = agent.tabLabel
                    }
                }
                for index in baseAgents.indices {
                    let agent = baseAgents[index]
                    guard let label = labels[agent.workspaceId]?[agent.tabId] else { continue }
                    if !reusesEnrichment {
                        let cutoff = min(deadline, tabEnrichment?.retained[agent.workspaceId] ?? deadline)
                        guard cutoff > now else { continue }
                        retained[agent.workspaceId] = cutoff
                    }
                    baseAgents[index].tabLabel = label
                }
            } else {
                verifiedTabSource = nil
            }
            spaces = Space.join(workspaces: workspaceList, agents: baseAgents)
            unconfirmedSpaces = SpacePresentationOverlay.unconfirmed(
                unconfirmedSpaces,
                after: spaces
            )
            if let event = AgentStatusAlerts.event(previous: alertBaseline, current: agentList) {
                playAlert(event)
            }
            alertBaseline = AgentStatusAlerts.snapshot(agentList)
            if let scope {
                connectionScope = scope
                lastUpdatedByPaneID = PaneLastUpdatedStore.observe(agentList, scope: scope)
            }
            lastUpdated = Date()
            errorMessage = nil
            guard let source, !tabWorkspaceIDs.isEmpty else { return }
            if reusesEnrichment { return }
            let predecessor = tabEnrichment?.task
            let cutoffs = Set(retained.values).sorted()
            let task = Task { [weak self] in
                let expiry = Task { [weak self] in
                    for cutoff in cutoffs {
                        do { try await ContinuousClock().sleep(until: cutoff) }
                        catch { return }
                        guard let self, self.ownsTabEnrichment(generation, scope: scope) else { return }
                        let expired = self.tabEnrichment?.retained.compactMap { $0.value <= cutoff ? $0.key : nil } ?? []
                        self.settleTabLabels([:], in: Set(expired), connection: connection, source: source)
                    }
                }
                defer {
                    expiry.cancel()
                    if let self, self.tabEnrichment?.id == generation {
                        if self.ownsTabEnrichment(generation, scope: scope), let pending = self.tabEnrichment {
                            self.settleTabLabels([:], in: Set(pending.retained.keys), connection: connection, source: source)
                        }
                        self.tabEnrichment = nil
                    }
                }
                await predecessor?.value
                guard !Task.isCancelled else { return }
                try? await connection.agentTabLabels(
                    workspaceIDs: tabWorkspaceIDs, generation: source, deadline: deadline
                ) { [weak self] workspace, result in
                    guard await connection.generation == source else { return }
                    let labels: [String: String]
                    switch result {
                    case let .completed(result): labels = result
                    case .failed: labels = [:]
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.ownsTabEnrichment(generation, scope: scope) else { return }
                        self.settleTabLabels(labels, in: [workspace], connection: connection, source: source)
                    }
                }
                if await connection.generation != source,
                   let self, self.ownsTabEnrichment(generation, scope: scope) {
                    self.clearVerifiedTabLabels()
                }
            }
            tabEnrichment = (generation, connection, source, retained, task)
        } catch {
            guard refreshGate.isCurrent(generation), connectionScope == initialScope else { return }
            reportError(error)
        }
    }

    private func ownsTabEnrichment(_ id: UInt64, scope: ConnectionIdentity?) -> Bool {
        guard let active = tabEnrichment else { return false }
        return active.id == id && !active.task.isCancelled && connectionScope == scope
            && canPublishTabLabels(from: active.source)
    }

    private func settleTabLabels(
        _ labels: [String: String], in workspaceIDs: Set<String>,
        connection: HerdrConnection, source: ConnectionGeneration
    ) {
        guard !workspaceIDs.isEmpty else { return }
        for id in workspaceIDs { tabEnrichment?.retained.removeValue(forKey: id) }
        let updated = spaces.map { space in
            guard workspaceIDs.contains(space.id), space.workspace.label
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return space }
            return Space(workspace: space.workspace, agents: space.agents.map { agent in
                var agent = agent
                agent.tabLabel = labels[agent.tabId]
                return agent
            })
        }
        verifiedTabSource = updated.contains { $0.agents.contains { $0.tabLabel != nil } } ? (connection, source) : nil
        if updated != spaces { spaces = updated }
    }

    func waitForTabEnrichment() async {
        await tabEnrichment?.task.value
    }

    func discardTabLabels(fromOtherGeneration generation: ConnectionGeneration?) {
        observedTabSource = .generation(generation)
        if let pending = tabEnrichment, pending.source != generation { pending.task.cancel() }
        if verifiedTabSource?.1 != generation { clearVerifiedTabLabels() }
    }

    private func canPublishTabLabels(from source: ConnectionGeneration) -> Bool {
        switch observedTabSource {
        case .unobserved: true
        case let .generation(generation): generation == source
        }
    }

    private func clearVerifiedTabLabels() {
        guard verifiedTabSource != nil else { return }
        verifiedTabSource = nil
        spaces = spaces.map { space in
            Space(workspace: space.workspace, agents: space.agents.map { agent in
                var agent = agent
                agent.tabLabel = nil
                return agent
            })
        }
    }

    private func reportError(_ error: Error) {
        let message = HerdrConnection.friendlyMessage(for: error)
        if !HerdrConnection.isDisconnectionOrTransitionMessage(message) {
            errorMessage = message
        }
    }

    /// Creates a new space on the Herdr machine. When `base` is set, the new
    /// space opens in that space's directory; `nil` lets herdr pick the
    /// default directory.
    func createSpace(basedOn base: Space?, _ connection: HerdrConnection) async {
        guard !isCreatingSpace else { return }
        spaceCreationGeneration += 1
        let generation = spaceCreationGeneration
        isCreatingSpace = true
        errorMessage = nil
        lastPresentedSpaceID = nil
        withAnimation(.snappy(duration: 0.28)) {
            pendingSpaceCreationTitle = base.map { "Creating space from \($0.label)…" } ?? "Creating space…"
        }
        defer {
            if spaceCreationGeneration == generation {
                isCreatingSpace = false
                withAnimation(.snappy(duration: 0.28)) {
                    pendingSpaceCreationTitle = nil
                }
            }
        }
        do {
            let target = connection
            let cwd = try await Self.baseWorkingDirectory(for: base, connection: target)
            guard spaceCreationGeneration == generation, !Task.isCancelled else { return }
            let created = (try await target.workspaceCreate(cwd: cwd)).workspace
            guard spaceCreationGeneration == generation, !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.28)) {
                if !spaces.contains(where: { $0.workspace.workspaceId == created.workspaceId }) {
                    unconfirmedSpaces.append(Space(workspace: created, agents: []))
                }
                pendingSpaceCreationTitle = nil
                lastPresentedSpaceID = created.workspaceId
            }
            await refresh(connection)
        } catch {
            guard spaceCreationGeneration == generation, !Task.isCancelled else { return }
            reportError(error)
        }
    }

    private(set) var isPerformingWorktreeAction = false

    /// Finds the default (root / primary non-linked) space for the repository of a given space,
    /// falling back to the space itself if none is found.
    func defaultSpace(for space: Space, in spaces: [Space]? = nil) -> Space {
        let pool = spaces ?? self.spaces
        guard let repoRoot = space.workspace.worktree?.repoRoot, !repoRoot.isEmpty else {
            return space
        }
        return pool.first { candidate in
            candidate.workspace.worktree?.repoRoot == repoRoot &&
            candidate.workspace.worktree?.isLinkedWorktree == false
        } ?? space
    }

    /// Opens an existing Git worktree in the specified space.
    func openWorktree(
        in space: Space,
        path: String? = nil,
        branch: String? = nil,
        _ connection: HerdrConnection
    ) async {
        guard !isPerformingWorktreeAction else { return }
        worktreeActionGeneration += 1
        let generation = worktreeActionGeneration
        let targetSpace = defaultSpace(for: space)
        isPerformingWorktreeAction = true
        errorMessage = nil
        lastPresentedSpaceID = nil
        highlightedWorktreeID = nil
        withAnimation(.snappy(duration: 0.28)) {
            pendingWorktreeAction = PendingWorktreeAction(
                sourceSpaceID: targetSpace.id,
                title: PendingWorktreeAction.openTitle(path: path, branch: branch)
            )
        }
        defer { finishWorktreeAction(generation) }
        do {
            let conn = connection
            let result: WorktreeOpenResult
            if targetSpace.workspace.worktree?.isLinkedWorktree == false {
                result = try await conn.worktreeOpen(
                    workspaceId: targetSpace.workspace.workspaceId,
                    path: path,
                    branch: branch
                )
            } else if let repoRoot = targetSpace.workspace.worktree?.repoRoot, !repoRoot.isEmpty {
                result = try await conn.worktreeOpen(
                    cwd: repoRoot,
                    path: path,
                    branch: branch
                )
            } else {
                result = try await conn.worktreeOpen(
                    workspaceId: targetSpace.workspace.workspaceId,
                    path: path,
                    branch: branch
                )
            }
            guard worktreeActionGeneration == generation, !Task.isCancelled else { return }
            presentWorktree(result.workspace, entry: result.worktree, source: targetSpace)
            await refresh(connection)
        } catch {
            guard worktreeActionGeneration == generation, !Task.isCancelled else { return }
            reportError(error)
        }
    }

    /// Creates and opens a new Git worktree based on the specified space.
    func createWorktree(
        in space: Space,
        name: String? = nil,
        label: String? = nil,
        _ connection: HerdrConnection
    ) async {
        guard !isPerformingWorktreeAction else { return }
        worktreeActionGeneration += 1
        let generation = worktreeActionGeneration
        let targetSpace = defaultSpace(for: space)
        isPerformingWorktreeAction = true
        errorMessage = nil
        lastPresentedSpaceID = nil
        highlightedWorktreeID = nil
        withAnimation(.snappy(duration: 0.28)) {
            pendingWorktreeAction = PendingWorktreeAction(
                sourceSpaceID: targetSpace.id,
                title: PendingWorktreeAction.createTitle(name: name, label: label)
            )
        }
        defer { finishWorktreeAction(generation) }
        do {
            let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = trimmedName?.isEmpty == false ? trimmedName : nil
            let labelText = trimmedLabel?.isEmpty == false ? trimmedLabel : nil
            let conn = connection

            let result: WorktreeCreateResult
            if targetSpace.workspace.worktree?.isLinkedWorktree == false {
                result = try await conn.worktreeCreate(
                    workspaceId: targetSpace.workspace.workspaceId,
                    branch: branch,
                    label: labelText
                )
            } else if let repoRoot = targetSpace.workspace.worktree?.repoRoot, !repoRoot.isEmpty {
                result = try await conn.worktreeCreate(
                    cwd: repoRoot,
                    branch: branch,
                    label: labelText
                )
            } else {
                result = try await conn.worktreeCreate(
                    workspaceId: targetSpace.workspace.workspaceId,
                    branch: branch,
                    label: labelText
                )
            }
            guard worktreeActionGeneration == generation, !Task.isCancelled else { return }
            presentWorktree(result.workspace, entry: result.worktree, source: targetSpace)
            await refresh(connection)
        } catch {
            guard worktreeActionGeneration == generation, !Task.isCancelled else { return }
            reportError(error)
        }
    }

    private func presentWorktree(_ workspace: Workspace, entry: WorktreeEntry?, source: Space) {
        let presented = WorktreePresentation.space(workspace, entry: entry, source: source)
        withAnimation(.snappy(duration: 0.28)) {
            if !spaces.contains(where: { $0.id == presented.id }) {
                unconfirmedSpaces.append(presented)
            }
            pendingWorktreeAction = nil
            lastPresentedSpaceID = presented.id
            highlightedWorktreeID = presented.id
        }
        let highlightedID = presented.id
        let generation = worktreeActionGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.worktreeActionGeneration == generation,
                  self?.highlightedWorktreeID == highlightedID else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                self?.highlightedWorktreeID = nil
            }
        }
    }

    private func finishWorktreeAction(_ generation: Int) {
        guard worktreeActionGeneration == generation else { return }
        isPerformingWorktreeAction = false
        withAnimation(.snappy(duration: 0.28)) {
            pendingWorktreeAction = nil
        }
    }

    private(set) var isPerformingSpaceAction = false

    /// Renames a space (Herdr workspace label).
    func renameSpace(_ space: Space, to name: String, _ connection: HerdrConnection) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isPerformingSpaceAction else { return }
        isPerformingSpaceAction = true
        defer { isPerformingSpaceAction = false }
        do {
            try await connection.workspaceRename(workspaceId: space.workspace.workspaceId, label: trimmed)
            await refresh(connection)
        } catch {
            reportError(error)
        }
    }

    /// Closes a space and removes it from the list after refresh.
    func closeSpace(_ space: Space, _ connection: HerdrConnection) async {
        guard !isPerformingSpaceAction else { return }
        isPerformingSpaceAction = true
        defer { isPerformingSpaceAction = false }
        do {
            try await connection.workspaceClose(workspaceId: space.workspace.workspaceId)
            await refresh(connection)
        } catch {
            reportError(error)
        }
    }

    /// Directory a new space inherits from the space it is based on: the
    /// checkout path when the space has repo metadata, else the first live
    /// pane's working directory.
    private static func baseWorkingDirectory(
        for base: Space?,
        connection: HerdrConnection
    ) async throws -> String? {
        guard let base else { return nil }
        if let checkout = base.workspace.worktree?.checkoutPath, !checkout.isEmpty {
            return checkout
        }
        let panes = try await connection.paneList(workspaceId: base.workspace.workspaceId)
        return panes.first { $0.cwd?.isEmpty == false }?.cwd
    }
}

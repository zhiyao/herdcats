import Foundation
import Observation

/// Memory-only state for one view/stream owner. Replies from retired owners
/// cannot restore old transcript data after pane changes or backgrounding.
@MainActor @Observable final class AgentTimelineState {
    enum Phase: Equatable {
        case loading, ready, suspended
        case unavailable(String)
        case disconnected
    }
    let modelControl = AgentModelControlState()
    /// The live bridge channel that submits Cursor prompts, or nil.
    private var promptClient: AgentBridgeClient?
    func connectPrompts(_ client: AgentBridgeClient?) { promptClient = client }
    /// A new Cursor chat has no transcript until its first prompt, so the view is
    /// waiting ("Send a message to start") and there is no identity to bind.
    var canSendFirstCursorPrompt: Bool { promptClient != nil && identity == nil && generation != nil && phase == .unavailable("transcript_unavailable") }
    /// Sends that first message through the bridge's screen guard, by pane and generation.
    func submitFirstCursorPrompt(_ text: String, paneId: String) async throws {
        guard let client = promptClient, canSendFirstCursorPrompt, let generation, paneId == self.paneId else {
            throw AgentBridgeError.unavailable("unsupported_capability")
        }
        try await client.submitFirstPrompt(text: text, paneId: paneId, generation: generation)
    }
    /// Sends one Cursor prompt through the bridge's screen guard. Throws the
    /// bridge's refusal code (approval_pending, composer_not_empty, ...).
    func submitCursorPrompt(_ text: String) async throws {
        guard let client = promptClient, let identity, let generation, identity.agent == "cursor" else {
            throw AgentBridgeError.unavailable("unsupported_capability")
        }
        try await client.submitPrompt(text: text, identity: identity, generation: generation)
    }
    private(set) var pendingQuestion: AgentPendingQuestion?
    private(set) var pendingApproval: AgentPendingApproval?
    private(set) var pendingPiDialog: AgentPiDialog?
    private var piClient: AgentBridgeClient?
    private(set) var isPiActionPending = false
    var piActionError: String?
    private(set) var entries: [AgentTimelineEntry] = []
    private(set) var identity: AgentTimelineIdentity?
    private(set) var phase: Phase = .loading
    private(set) var generation: UInt64?
    private(set) var hasMore = false
    private(set) var before: String?
    private(set) var agentStatus: String?
    private(set) var unknownRecords = 0
    private(set) var droppedEntries = 0
    private(set) var delayed = false
    /// `codex_daemon` carried by the latest unavailable event (running /
    /// not_running / unknown); nil otherwise, including unrecognized values.
    private(set) var codexDaemon: String?
    private(set) var revision: UInt64 = 0
    private var owner: UUID?
    private var paneId = ""
    private var epoch: String?
    private var sequence: UInt64 = 0
    private var evictedIds: Set<String> = []

    private var connectionScope: AgentTimelineConnectionState?
    private var agentScope: String?

    /// A scene-only restart can retain verified history, never interactive clients.
    func begin(owner: UUID, paneId: String, connection: AgentTimelineConnectionState? = nil, isActive: Bool = true, agent: String? = nil) {
        let retain = self.paneId == paneId && connection != nil
            && connectionScope == connection && connection?.isReady == true && identity != nil
            && TimelineAgentAvailability.canonical(identity?.agent) == TimelineAgentAvailability.canonical(agent)
        retireClients()
        self.owner = owner
        self.paneId = paneId
        connectionScope = connection
        agentScope = TimelineAgentAvailability.canonical(agent)
        epoch = nil
        sequence = 0
        if !retain { clear() }
        phase = isActive && (connection?.isReady ?? true) ? .loading : .suspended
    }

    /// Check live view inputs too: they can change before a replacement task begins.
    func matchesLivePane(paneId: String, agent: String?, connection: AgentTimelineConnectionState) -> Bool {
        connectionScope == connection && self.paneId == paneId
            && TimelineAgentAvailability.canonical(identity?.agent ?? agentScope) == TimelineAgentAvailability.canonical(agent)
    }

    func hasSnapshot(for connection: AgentTimelineConnectionState, paneId: String, agent: String?) -> Bool {
        connection.isReady && connectionScope == connection && identity != nil
            && identity?.paneId == paneId && matchesLivePane(paneId: paneId, agent: agent, connection: connection)
    }

    /// View presentation also consults live eligibility before a replacement task runs.
    func presentationPhase(connection: AgentTimelineConnectionState, isActive: Bool, paneId: String, agent: String?) -> Phase {
        guard isActive, connection.isReady else { return .suspended }
        guard matchesLivePane(paneId: paneId, agent: agent, connection: connection),
              connectionScope == nil || connectionScope == connection else { return .loading }
        return phase
    }

    func retire(owner: UUID, preservingContent: Bool = true) {
        guard self.owner == owner else { return }
        self.owner = nil
        retireClients()
        if !preservingContent { clear() }
        phase = .suspended
    }

    private func retireClients() {
        piClient = nil
        promptClient = nil
        modelControl.connect(nil, supported: false)
        modelControl.reset()
        pendingQuestion = nil
        pendingApproval = nil
        pendingPiDialog = nil
        isPiActionPending = false
        piActionError = nil
    }

    func consume(_ frame: AgentBridgeFrame, owner: UUID) throws {
        guard self.owner == owner else { return }
        guard let event = frame.event, let nextEpoch = frame.epoch, let seq = frame.seq, let data = frame.data
        else { throw AgentBridgeError.invalidFrame }
        guard epoch == nil || epoch == nextEpoch, seq == sequence + 1 else {
            throw AgentBridgeError.sequenceGap
        }
        epoch = nextEpoch
        sequence = seq
        switch event {
        case "timeline.unavailable":
            guard data.paneId == paneId, let next = data.generation else {
                throw AgentBridgeError.identityMismatch
            }
            clear()
            generation = next
            codexDaemon = Self.normalizedCodexDaemon(data.codexDaemon)
            phase = .unavailable(data.code ?? "timeline_unavailable")
        case "timeline.snapshot":
            guard let nextIdentity = data.identity, nextIdentity.paneId == paneId,
                TimelineAgentAvailability.supports(agent: nextIdentity.agent),
                agentScope == nil || TimelineAgentAvailability.canonical(nextIdentity.agent) == agentScope,
                let next = data.generation, let rows = data.entries
            else { throw AgentBridgeError.identityMismatch }
            try validate(rows)
            clear()
            identity = nextIdentity
            generation = next
            modelControl.bind(identity: nextIdentity, generation: next)
            if data.model != nil { try modelControl.update(data) }
            entries = rows
            hasMore = data.hasMore ?? false
            before = data.before
            agentStatus = data.agentStatus
            unknownRecords = data.unknownRecords ?? 0
            droppedEntries = data.droppedEntries ?? 0
            delayed = data.delayed ?? false
            phase = .ready
            revision += 1
        case "timeline.updated":
            guard phase == .ready, data.identity == identity, data.generation == generation,
                let rows = data.entries
            else { throw AgentBridgeError.identityMismatch }
            try validate(rows)
            let removed = data.evictedIds ?? []
            guard removed.count <= 1000, removed.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 264 }) else {
                throw AgentBridgeError.invalidFrame
            }
            let removedSet = Set(removed)
            guard evictedIds.union(removedSet).count <= 100_000 else { throw AgentBridgeError.invalidFrame }
            evictedIds.formUnion(removedSet)
            entries.removeAll { removedSet.contains($0.id) }
            if let cursor = before, removedSet.contains(cursor) {
                before = entries.first?.id
                hasMore = false
            }
            var entryIndex: [String: Int] = [:]
            for (index, entry) in entries.enumerated() {
                entryIndex[entry.id] = index
            }
            for row in rows where !evictedIds.contains(row.id) {
                if let index = entryIndex[row.id] {
                    entries[index] = row
                } else {
                    entryIndex[row.id] = entries.count
                    entries.append(row)
                }
            }
            if entries.count > 1000 {
                entries.removeFirst(entries.count - 1000)
                // Older local entries were discarded; history can still be
                // requested relative to the first retained entity.
                hasMore = true
                before = entries.first?.id
            }
            agentStatus = data.agentStatus ?? agentStatus
            unknownRecords = data.unknownRecords ?? unknownRecords
            droppedEntries = data.droppedEntries ?? droppedEntries
            delayed = data.delayed ?? delayed
            revision += 1
        case "pi.dialog":
            guard phase == .ready, data.identity == identity, data.generation == generation else { throw AgentBridgeError.identityMismatch }
            pendingPiDialog = try AgentPiDialog.decode(data)
            piActionError = nil
            revision += 1
        case "pi.dialog.cleared":
            guard phase == .ready, data.identity == identity, data.generation == generation else { throw AgentBridgeError.identityMismatch }
            if data.requestId == pendingPiDialog?.requestId { pendingPiDialog = nil; revision += 1 }
        case "model.updated":
            guard phase == .ready, data.identity == identity, data.generation == generation else {
                throw AgentBridgeError.identityMismatch
            }
            try modelControl.update(data)
        case "interaction.pending":
            guard phase == .ready, data.identity == identity, data.generation == generation else {
                throw AgentBridgeError.identityMismatch
            }
            if data.kind == "question" {
                pendingQuestion = try AgentPendingQuestion.decode(data)
                pendingApproval = nil
            } else {
                pendingApproval = try AgentPendingApproval.decode(data)
                pendingQuestion = nil
            }
            revision += 1
        case "interaction.resolved":
            guard let requestId = data.requestId, !requestId.isEmpty, requestId.utf8.count <= 264 else {
                throw AgentBridgeError.invalidFrame
            }
            if let pending = pendingApproval, pending.requestId == requestId,
                pending.identity == data.identity, pending.generation == data.generation {
                pendingApproval = nil
                revision += 1
            }
            if let pending = pendingQuestion, pending.requestId == requestId,
                pending.identity == data.identity, pending.generation == data.generation {
                pendingQuestion = nil
                revision += 1
            }
        default: throw AgentBridgeError.invalidFrame
        }
    }
    func mergeHistory(_ page: AgentBridgePayload, owner: UUID, generation: UInt64) throws {
        guard self.owner == owner, self.generation == generation else { return }
        guard page.generation == generation, page.identity == identity, let rows = page.entries else {
            throw AgentBridgeError.identityMismatch
        }
        try validate(rows)
        let currentIds = Set(entries.map(\.id))
        let prefix = rows.filter { !currentIds.contains($0.id) && !evictedIds.contains($0.id) }
        // Never let a delayed history page overwrite a streamed revision.
        entries = Array((prefix + entries).suffix(1000))
        if !rows.contains(where: { evictedIds.contains($0.id) }) {
            hasMore = (page.hasMore ?? false) && entries.count < 1000
        }
        before = entries.first?.id
        droppedEntries = page.droppedEntries ?? droppedEntries
    }
    func end(owner: UUID, error: AgentBridgeError) {
        guard self.owner == owner else { return }
        guard !Task.isCancelled else {
            retire(owner: owner)
            return
        }
        retireClients()
        self.owner = nil
        clear()
        phase = error == .closed ? .disconnected : .unavailable(error.code)
    }
    private func clear() {
        modelControl.reset()
        pendingQuestion = nil
        pendingApproval = nil
        pendingPiDialog = nil
        isPiActionPending = false
        piActionError = nil
        evictedIds.removeAll()
        entries = []
        identity = nil
        generation = nil
        before = nil
        hasMore = false
        agentStatus = nil
        unknownRecords = 0
        droppedEntries = 0
        delayed = false
        codexDaemon = nil
        revision += 1
    }

    func connectPi(_ client: AgentBridgeClient?) { piClient = client }
    var canSubmitPiPrompt: Bool { identity?.agent == "pi" && phase == .ready && piClient != nil && !isPiActionPending && pendingPiDialog == nil && ["idle", "done"].contains(agentStatus ?? "") }
    var canCancelPi: Bool { identity?.agent == "pi" && phase == .ready && piClient != nil && !isPiActionPending && agentStatus == "working" && pendingPiDialog == nil }
    func submitPiPrompt(_ text: String) async throws {
        guard canSubmitPiPrompt, let client = piClient, let identity, let generation else { throw AgentBridgeError.unavailable("agent_busy") }
        let reply = try await client.piAction(.piPrompt, identity: identity, generation: generation, text: text)
        guard reply.confirmed == true else { throw AgentBridgeError.unavailable("delivery_unconfirmed") }
    }
    func cancelPi() async { await performPiAction(.piCancel) }
    func respondPiDialog(_ dialog: AgentPiDialog, value: AgentPiDialogValue) async {
        guard pendingPiDialog == dialog, dialog.accepts(value) else { return }
        await performPiAction(.piDialogRespond, dialog: dialog, value: value)
    }
    private func performPiAction(_ method: AgentBridgeMethod, dialog: AgentPiDialog? = nil, value: AgentPiDialogValue? = nil) async {
        guard !isPiActionPending, phase == .ready, let client = piClient, let identity, let generation, let owner else { return }
        guard method != .piCancel || canCancelPi else { return }
        isPiActionPending = true
        piActionError = nil
        do {
            let reply = try await client.piAction(method, identity: identity, generation: generation, requestId: dialog?.requestId, value: value)
            guard self.owner == owner, self.identity == identity, self.generation == generation else { return }
            guard reply.confirmed == true, dialog == nil || reply.requestId == dialog?.requestId else { throw AgentBridgeError.invalidFrame }
        } catch {
            guard self.owner == owner, self.identity == identity, self.generation == generation else { return }
            piActionError = (error as? AgentBridgeError)?.code == "stale"
                ? "This Pi session changed. Check the current request and try again."
                : "Could not confirm delivery. Check Terminal before trying again."
        }
        if self.owner == owner, self.identity == identity, self.generation == generation { isPiActionPending = false }
    }

    /// Older bridges omit `codex_daemon`; future values the app does not know
    /// stay nil so the pane never offers an action from an unverified state.
    static func normalizedCodexDaemon(_ value: String?) -> String? {
        guard ["running", "not_running", "unknown"].contains(value ?? "") else { return nil }
        return value
    }
    private func validate(_ rows: [AgentTimelineEntry]) throws {
        guard rows.count <= 1000, Set(rows.map(\.id)).count == rows.count,
            rows.allSatisfy({
                !$0.id.isEmpty && $0.id.utf8.count <= 264 && ["message", "tool", "image", "record"].contains($0.kind)
                    && $0.text.utf8.count <= 8192 && ($0.details?.utf8.count ?? 0) <= 8192
                    && ($0.contentRef.map { TimelineContentReference.length($0) != nil } ?? !["image", "record"].contains($0.kind))
                    && ($0.recordRefs?.count ?? 0) <= 4
                    && ($0.recordRefs ?? []).allSatisfy { TimelineContentReference.length($0) != nil }
            })
        else { throw AgentBridgeError.invalidFrame }
    }
}

/// The page belongs to the timeline, not SwiftUI's short-lived refresh gesture.
/// Concurrent pulls share a request; leaving the timeline explicitly cancels it.
@MainActor final class TimelineHistoryLoader {
    private var task: Task<Void, Never>?
    private var token: UUID?

    func load(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let token = UUID()
        let task = Task { await operation() }
        self.token = token
        self.task = task
        await task.value
        if self.token == token {
            self.task = nil
            self.token = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        token = nil
    }
}

/// Shares the watched bridge with the composer. Every async reply is scoped to
/// the same occupant and generation; retiring a timeline invalidates pending UI work.
@MainActor @Observable final class AgentModelControlState {
    private(set) var supported = false
    fileprivate(set) var pair = AgentModelPair()
    fileprivate(set) var models: [AgentModelOption] = []
    /// `model.status`'s top-level efforts, used when no model row is selected
    /// (a fresh Claude session can report no model but still offer efforts).
    private var statusEfforts: [AgentEffortOption] = []
    private(set) var isChanging = false
    private(set) var isLoadingModels = false
    /// Provenance of `models`, from the same reply and scope as the list.
    private(set) var catalogInfo: AgentModelCatalogInfo?
    var errorMessage: String?
    private var client: AgentBridgeClient?
    private var identity: AgentTimelineIdentity?
    private var generation: UInt64?
    private var revision: UInt64 = 0
    private var scope = UUID()

    var isVisible: Bool { supported && identity != nil }
    /// Cursor writes the choice to its own config, so it also becomes the default for new sessions.
    var persistsAcrossSessions: Bool { identity?.agent == "cursor" }
    /// The live model's own label keeps its version ("Opus 5.5"); the catalog
    /// name is used only when the bridge sent a bare id as the label.
    var modelName: String {
        let model = pair.model.flatMap { $0.label != $0.id ? $0 : nil } ?? selectedModel ?? pair.model
        guard let model else { return "Model" }
        return model.label
    }
    var effortText: String? { pair.effort?.lowercased() }
    var label: String { modelName + (effortText.map { " " + $0 } ?? "") }
    var accessibilityLabel: String {
        "Model \(pair.model == nil ? "unknown" : modelName)" + (effortText.map { ", effort " + $0 } ?? "")
    }
    /// The exact row, else the row the bridge marked current. The bridge marks
    /// an alias current only when it resolves to exactly the running id, so an
    /// older `claude-haiku-4-5` never checks the `haiku` (5.5) row.
    var selectedModel: AgentModelOption? {
        models.first(where: { $0.id == pair.model?.id })
            ?? models.first(where: { $0.current == true })
    }
    var efforts: [AgentEffortOption] {
        if let selectedModel { return selectedModel.efforts }
        if let efforts = pair.model?.efforts, !efforts.isEmpty { return efforts }
        return statusEfforts
    }
    var effortLabel: String {
        guard let effort = pair.effort else { return "Default" }
        return efforts.first(where: { $0.id == effort })?.label ?? "Unknown"
    }
    var selectedModelID: String? { selectedModel?.id }

    func connect(_ client: AgentBridgeClient?, supported: Bool) {
        self.client = client
        self.supported = supported
    }
    func reset() {
        scope = UUID()
        revision += 1
        identity = nil
        generation = nil
        pair = AgentModelPair()
        models = []
        statusEfforts = []
        catalogInfo = nil
        errorMessage = nil
        isChanging = false
        isLoadingModels = false
    }
    func bind(identity: AgentTimelineIdentity, generation: UInt64) {
        self.identity = identity
        self.generation = generation
    }
    func update(_ payload: AgentBridgePayload, options: Bool = false) throws {
        guard payload.identity == identity, payload.generation == generation else { throw AgentBridgeError.identityMismatch }
        if options {
            guard let models = payload.models else { throw AgentBridgeError.invalidFrame }
            self.models = models
            statusEfforts = payload.efforts ?? []
            catalogInfo = payload.catalog
        }
        let model = payload.model.map { incoming in
            if options { return incoming }
            if pair.model?.id == incoming.id, let known = pair.model { return known }
            return models.first(where: { $0.id == incoming.id }) ?? incoming
        }
        let previous = pair.model?.id
        pair = AgentModelPair(model: model, effort: payload.effort)
        if models.contains(where: { $0.id == model?.id }) {
            for index in models.indices { models[index].current = models[index].id == model?.id }
        } else if !options, model?.id != previous {
            // A streamed model outside the list (a desk-side switch to another
            // version): only the bridge knows which row, if any, it matches,
            // so drop the stale mark and refetch the catalog.
            for index in models.indices { models[index].current = false }
            Task { await refresh() }
        }
        revision += 1
    }
    func refresh() async {
        guard supported, let client, let identity, let generation, !isLoadingModels else { return }
        let revision = revision
        let scope = scope
        isLoadingModels = true
        errorMessage = nil
        defer {
            if self.scope == scope { isLoadingModels = false }
        }
        do {
            let payload = try await client.modelStatus()
            guard let catalog = payload.models else { throw AgentBridgeError.invalidFrame }
            guard !catalog.isEmpty else { throw AgentBridgeError.unavailable("agy_catalog_empty") }
            guard self.scope == scope, self.identity == identity, self.generation == generation else { return }
            if self.revision != revision {
                // An event already supplied a newer pair; the catalog is still useful.
                guard payload.identity == identity, payload.generation == generation,
                    let models = payload.models else { throw AgentBridgeError.identityMismatch }
                self.models = models
                statusEfforts = payload.efforts ?? []
                catalogInfo = payload.catalog
                errorMessage = nil
                return
            }
            try update(payload, options: true)
            errorMessage = nil
        } catch {
            guard self.scope == scope, self.identity == identity, self.generation == generation else { return }
            models = []
            statusEfforts = []
            errorMessage = Self.catalogMessage(for: (error as? AgentBridgeError)?.code)
        }
    }
    func change(model: String? = nil, effort: String? = nil) async {
        guard !isChanging, supported, let client, let identity, let generation else { return }
        isChanging = true
        errorMessage = nil
        let scope = scope
        do {
            let payload = try await client.setModel(model: model, effort: effort,
                expect: AgentModelExpectation(model: pair.model?.id, effort: pair.effort,
                    identity: ["antigravity_cli", "pi", "cursor"].contains(TimelineAgentAvailability.canonical(identity.agent) ?? "") ? identity : nil,
                    generation: ["antigravity_cli", "pi", "cursor"].contains(TimelineAgentAvailability.canonical(identity.agent) ?? "") ? generation : nil))
            guard self.scope == scope, self.identity == identity, self.generation == generation else { return }
            try apply(payload)
        } catch {
            guard self.scope == scope, self.identity == identity, self.generation == generation else { return }
            errorMessage = Self.message(for: (error as? AgentBridgeError)?.code)
            // Refresh the observed pair after a stale expect; never retry a send.
            if (error as? AgentBridgeError)?.code == "stale" {
                await refreshKeepingError()
            }
        }
        if self.identity == identity, self.generation == generation, self.scope == scope { isChanging = false }
    }
    private func refreshKeepingError() async {
        let message = errorMessage
        let scope = scope
        await refresh()
        if self.scope == scope { errorMessage = message }
    }
    func apply(_ payload: AgentBridgePayload) throws {
        guard payload.identity == identity, payload.generation == generation else { throw AgentBridgeError.identityMismatch }
        guard let applied = payload.applied, let confirmed = payload.confirmed else { throw AgentBridgeError.invalidFrame }
        pair = applied
        for index in models.indices { models[index].current = models[index].id == applied.model?.id }
        revision += 1
        errorMessage = confirmed ? nil : Self.message(for: payload.error)
    }
    static func catalogMessage(for code: String?) -> String {
        switch code {
        case "agy_unavailable": return "Agy wasn't found on this computer. Update Herdcats Bridge or check the Agy installation, then retry."
        case "agy_timeout", "timeout": return "Loading model choices timed out. Retry or use Terminal."
        case "agy_unsupported_version": return "This Agy version hasn't been verified for model controls. Use Terminal."
        case "agy_catalog_invalid": return "Agy returned model choices Herdcats couldn't read. Retry or use Terminal."
        case "codex_unavailable": return "Codex wasn't found on this computer. Check the Codex installation, then retry."
        case "codex_catalog_invalid": return "Codex returned model choices Herdcats couldn't read. Retry or use Terminal."
        case "codex_catalog_missing", "codex_catalog_empty": return "Codex has no model choices yet. Retry or use Terminal."
        case "agy_catalog_empty": return "No model choices were returned. Retry or use Terminal."
        case "agent_busy": return "The agent is busy. Retry when it's idle."
        case "unsupported_capability": return "This bridge doesn't support model choices. Update Herdcats Bridge, then retry."
        default: if let cursor = cursorMessage(for: code) { return cursor }
            return "Couldn't load model choices. Retry or use Terminal."
        }
    }
    static func message(for code: String?) -> String {
        switch code {
        case "agent_busy": return "The agent is working — try again when it's idle."
        case "stale": return "Something changed at the desk. Check the current model and try again."
        case "composer_not_empty": return "Clear the agent's input box at the desk first."
        default: if let cursor = cursorMessage(for: code) { return cursor }
            return "Couldn't change the model. Try again."
        }
    }
    /// Cursor's guarded model menu refuses rather than guesses; each refusal says what to do.
    static func cursorMessage(for code: String?) -> String? {
        switch code {
        case "cursor_unsupported_version": return "This Cursor version hasn't been verified for model controls. Use Terminal."
        case "cursor_version_unverified": return "Herdcats can't tell which Cursor version is running. Use Terminal."
        case "mode_not_agent": return "Switch Cursor back to Agent mode at the desk, then retry."
        case "composer_not_empty": return "Clear Cursor's input box at the desk first, or use Terminal."
        case "approval_pending": return "Cursor is waiting for a permission decision. Answer it first, or use Terminal."
        case "question_pending": return "Cursor is waiting for an answer to its question. Answer it first, or use Terminal."
        case "picker_open": return "A Cursor menu is open at the desk. Close it first, or use Terminal."
        case "footer_unrecognized": return "Herdcats can't read which model Cursor is using (a custom status line?). Use Terminal."
        case "unknown_model": return "Cursor doesn't list that model. Refresh the choices, or use Terminal."
        case "invalid_effort": return "That model doesn't offer that effort. Use Terminal."
        case "picker_stuck": return "Cursor's model menu may still be open. Close it in Terminal."
        case "picker_mismatch", "picker_unavailable", "catalog_incomplete", "catalog_ambiguous", "screen_unrecognized", "screen_unavailable":
            return "Cursor's model menu didn't look as expected, so nothing was changed. Use Terminal."
        case "confirm_timeout": return "Couldn't confirm the change in Cursor. Check the model at the desk."
        default: return nil
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
extension AgentModelControlState {
    /// Screenshot-only catalog for `-hc.screen timeline-model*`; requires a bound identity.
    func loadScreenshotFixture(agent: String) async {
        if TimelineAgentAvailability.canonical(agent) == "antigravity_cli" {
            guard let identity, let generation else { return }
            let efforts = ["low", "medium", "high"].map { AgentEffortOption(id: $0, label: $0.capitalized) }
            let catalog = [("gemini-3.8-flash", "Gemini 3.8 Flash"), ("gemini-4-argon", "Gemini 4 Argon"),
                ("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                ("gpt-oss-120b", "GPT-OSS 120B")].map { id, label in
                    AgentModelOption(id: id, label: label, efforts: id == "gpt-oss-120b" ? [efforts[1]] : efforts)
                }
            pair = AgentModelPair(model: catalog[0], effort: "high")
            if ScreenshotFixtures.screen == "timeline-model-agy-retry" {
                let client = await AgentTimelineScreenshotFixture.modelCatalogClient(identity: identity, generation: generation, models: catalog)
                models = []
                connect(client, supported: true)
            } else {
                models = catalog
                connect(nil, supported: true)
            }
            return
        }
        let efforts = ["low", "medium", "high", "xhigh", "max"].map {
            AgentEffortOption(id: $0, label: $0 == "xhigh" ? "Extra high" : $0.capitalized)
        }
        let models = agent == "codex"
            ? ["GPT-6.1-Sol", "GPT-6-Astra", "GPT-6-Sol", "GPT-6-Luna", "GPT-5.6-Sol", "GPT-5.6-Terra", "GPT-5.6-Luna"]
                .map { AgentModelOption(id: $0.lowercased(), label: $0, efforts: efforts) }
            : ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"]
                .map { AgentModelOption(id: $0.split(separator: " ")[0].lowercased(), label: $0, efforts: efforts) }
        connect(nil, supported: true)
        self.models = models
        pair = AgentModelPair(model: models[agent == "codex" ? 0 : 1], effort: "high")
    }
}
#endif

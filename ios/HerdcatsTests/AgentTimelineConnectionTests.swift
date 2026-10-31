import Foundation
import Testing
import UIKit

@testable import Herdcats

@Suite("Agent timeline connection lifetime")
@MainActor struct AgentTimelineConnectionTests {
    @Test func cancelledCurrentRunDoesNotPublishDisconnected() async {
        let store = AgentTimelineState()
        let owner = UUID()
        store.begin(owner: owner, paneId: "p1")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            store.end(owner: owner, error: .closed)
        }
        await task.value
        #expect(store.phase != .disconnected)
        #expect(store.entries.isEmpty)
        #expect(store.identity == nil)
    }

    @Test func unexpectedCurrentChannelCloseStillPublishesFailureBeforeSnapshot() {
        let store = AgentTimelineState()
        let owner = UUID()
        store.begin(owner: owner, paneId: "p1")
        store.end(owner: owner, error: .closed)
        #expect(store.phase == .disconnected)
    }

    @Test func inactiveAndConnectingPreflightAreSuspendedNotFailed() {
        let store = AgentTimelineState()
        let connected = AgentTimelineConnectionState(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1))
        let connecting = AgentTimelineConnectionState(phase: .connecting, generation: .init(rawValue: 1))
        let owner = UUID()
        store.begin(owner: owner, paneId: "p1", connection: connected, isActive: false)
        #expect(store.phase == .suspended)
        store.begin(owner: UUID(), paneId: "p1", connection: connecting)
        #expect(store.phase == .suspended)
        store.begin(owner: UUID(), paneId: "p1", connection: connected)
        #expect(store.phase == .loading)
    }

    @Test func liveEligibilitySuppressesPriorFailureBeforeReplacementTaskStarts() {
        let store = AgentTimelineState(), owner = UUID()
        let connected = AgentTimelineConnectionState(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1))
        store.begin(owner: owner, paneId: "p1", connection: connected)
        store.end(owner: owner, error: .closed)
        #expect(store.presentationPhase(connection: connected, isActive: true, paneId: "p1", agent: nil) == .disconnected)
        #expect(store.presentationPhase(connection: connected, isActive: false, paneId: "p1", agent: nil) == .suspended)
        #expect(store.presentationPhase(connection: .init(phase: .connecting, generation: .init(rawValue: 1)), isActive: true, paneId: "p1", agent: nil) == .suspended)
        #expect(store.presentationPhase(connection: .init(phase: .offline(host: "h", username: "u"), generation: nil), isActive: true, paneId: "p1", agent: nil) == .suspended)
        #expect(store.presentationPhase(connection: .init(phase: connected.phase, generation: .init(rawValue: 2)), isActive: true, paneId: "p1", agent: nil) == .loading)
    }

    @Test func sceneRetirementRetainsOnlySameScopeVerifiedHistory() throws {
        let store = AgentTimelineState(), owner = UUID()
        let connected = AgentTimelineConnectionState(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1))
        store.begin(owner: owner, paneId: "p1", connection: connected, agent: "claude")
        let snapshot = try AgentBridgeFrame.decode(Data(#"{"event":"timeline.snapshot","epoch":"e","seq":1,"data":{"identity":{"pane_id":"p1","terminal_id":"t","agent":"claude","native_session_id":"s"},"generation":1,"entries":[{"id":"m","kind":"message","text":"private history","role":"assistant","truncated":false}]}}"#.utf8))
        try store.consume(snapshot, owner: owner)
        store.retire(owner: owner)
        #expect(store.phase == .suspended)
        #expect(store.hasSnapshot(for: connected, paneId: "p1", agent: "claude"))
        #expect(store.entries.first?.text == "private history")
        let replacement = UUID()
        store.begin(owner: replacement, paneId: "p1", connection: connected, agent: "claude")
        #expect(store.phase == .loading)
        #expect(store.hasSnapshot(for: connected, paneId: "p1", agent: "claude"))
        store.end(owner: owner, error: .closed)
        #expect(store.phase == .loading)
        store.begin(owner: UUID(), paneId: "p1", connection: .init(phase: connected.phase, generation: .init(rawValue: 2)))
        #expect(store.entries.isEmpty)
        #expect(store.identity == nil)
        #expect(!store.hasSnapshot(for: connected, paneId: "p1", agent: "claude"))
    }

    @Test func livePaneAndAgentScopeHideSnapshotBeforeReplacementBegins() throws {
        let store = AgentTimelineState(), owner = UUID()
        let connected = AgentTimelineConnectionState(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1))
        store.begin(owner: owner, paneId: "p1", connection: connected)
        let frame = try AgentBridgeFrame.decode(Data(#"{"event":"timeline.snapshot","epoch":"e","seq":1,"data":{"identity":{"pane_id":"p1","terminal_id":"t","agent":"claude","native_session_id":"private-session"},"generation":1,"entries":[{"id":"m","kind":"message","text":"pane A private","role":"assistant","truncated":false}]}}"#.utf8))
        try store.consume(frame, owner: owner)
        #expect(store.hasSnapshot(for: connected, paneId: "p1", agent: "claude"))
        // The live SwiftUI inputs changed; no replacement begin() has executed yet.
        #expect(!store.hasSnapshot(for: connected, paneId: "p2", agent: "claude"))
        #expect(!store.hasSnapshot(for: connected, paneId: "p1", agent: "codex"))
        #expect(store.presentationPhase(connection: connected, isActive: true, paneId: "p2", agent: "claude") == .loading)
        #expect(store.presentationPhase(connection: connected, isActive: true, paneId: "p1", agent: "codex") == .loading)
        #expect(!store.matchesLivePane(paneId: "p2", agent: "claude", connection: connected))
        #expect(!store.matchesLivePane(paneId: "p1", agent: "codex", connection: connected))
        #expect(store.matchesLivePane(paneId: "p1", agent: "claude", connection: connected))
        let replacementTransport = AgentTimelineConnectionState(phase: connected.phase, generation: .init(rawValue: 2))
        #expect(!store.matchesLivePane(paneId: "p1", agent: "claude", connection: replacementTransport))
        #expect(store.entries.first?.text == "pane A private") // Hide, not mutate the old owner's data.
    }

    @Test func unavailableSymbolsKeepFirstMessageDistinctFromUnidentifiedSessions() {
        let stop = AgentBridgeCapabilities(claudeTimeline: true, codexTimeline: true, codexDaemonStop: true)
        for code in ["session_reference_unavailable", "ambiguous_session", "invalid_session_reference"] {
            #expect(AgentTimelineView.availabilitySymbol(code: code, agent: "cursor", capabilities: nil, codexDaemon: nil) == "questionmark.bubble")
            #expect(AgentTimelineView.availabilitySymbol(code: code, agent: "codex", capabilities: stop, codexDaemon: "running") == "questionmark.bubble")
        }
        #expect(AgentTimelineView.availabilitySymbol(code: "session_reference_unavailable", agent: "codex", capabilities: stop, codexDaemon: "not_running") == "bubble.left")
        #expect(AgentTimelineView.availabilitySymbol(code: "session_cwd_mismatch", agent: "codex", capabilities: nil, codexDaemon: nil) == "questionmark.bubble")
        for code in ["helper_missing", "helper_update_required", "transcript_unavailable", "protocol_mismatch", "unsafe_transcript_path"] {
            #expect(AgentTimelineView.availabilitySymbol(code: code, agent: "claude", capabilities: nil, codexDaemon: nil) == "bubble.left")
        }
        for name in ["bubble.left", "questionmark.bubble", "calendar.day.timeline.left"] {
            #expect(UIImage(systemName: name) != nil)
        }
    }

    @Test func connectingAndConnectedHaveDifferentStreamKeys() {
        let connecting = AgentTimelineConnectionState(
            phase: .connecting, generation: ConnectionGeneration(rawValue: 2))
        let connected = AgentTimelineConnectionState(
            phase: .connected(host: "host", username: "user"), generation: ConnectionGeneration(rawValue: 2))
        #expect(connecting != connected)
        #expect(!connecting.isReady)
        #expect(connected.isReady)
        #expect(
            connected
                != AgentTimelineConnectionState(
                    phase: .connected(host: "host", username: "user"),
                    generation: ConnectionGeneration(rawValue: 3)))
    }
    @Test func delayedCallbackCannotCommitAfterTransportGenerationChanges() async throws {
        let model = AppModel(autoConnectOnLaunch: false)
        model.phase = .connected(host: "host", username: "user")
        let captured = AgentTimelineConnectionState(
            phase: model.phase, generation: ConnectionGeneration(rawValue: 1))
        let store = AgentTimelineState()
        let owner = UUID()
        store.begin(owner: owner, paneId: "w1:p1")
        let frame = try AgentBridgeFrame.decode(
            Data(
                "{\"event\":\"timeline.snapshot\",\"epoch\":\"e\",\"seq\":1,\"data\":{\"identity\":{\"pane_id\":\"w1:p1\",\"terminal_id\":\"t\",\"agent\":\"claude\",\"native_session_id\":\"s\"},\"generation\":1,\"entries\":[]}}"
                    .utf8))
        let next = AgentTimelineConnectionState(
            phase: model.phase, generation: ConnectionGeneration(rawValue: 2))
        #expect(throws: AgentBridgeError.self) { try captured.requireCurrent(next) }
        // The same main-actor commit gate used by the view rejects a delayed
        // event before touching its store, even if its view token is unchanged.
        do {
            try captured.requireCurrent(next)
            try store.consume(frame, owner: owner)
        } catch {}
        #expect(store.phase == .loading)
        #expect(store.identity == nil)
    }
    @Test func removedBridgeRegistryRejectsQueuedEventBeforeAsyncClose() async {
        let connection = HerdrConnection()
        let bridge = AgentBridgeClient(write: { _ in }, close: {}, onEvent: { _ in })
        await connection.registerBridgeForTest(bridge)
        let generation = await connection.generation
        #expect(await connection.agentBridgeCanDeliver(bridgeId: bridge.id, owned: generation))
        await connection.closeAllAgentBridges()
        #expect(await !connection.agentBridgeCanDeliver(bridgeId: bridge.id, owned: generation))
    }
}
extension HerdrConnection {
    fileprivate func registerBridgeForTest(_ bridge: AgentBridgeClient) { agentBridges[bridge.id] = bridge }
}

// Controlled transport boundary; all lifecycle decisions are made by the real runner.
@MainActor private final class TimelineRunHarness {
    let state = AgentTimelineState()
    var key = AgentTimelineView.TaskKey(paneId: "p1", agent: "claude",
        connection: .init(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1)), isActive: true, retry: 0)
    var owner: UUID?
    var recorded = AgentTimelineStreamRunner.Metadata()
    var published: [AgentTimelineStreamRunner.Metadata] = []
    var phases: [AgentTimelineState.Phase] = []
    var openCount = 0
    var metadataReads = 0
    var metadataHook: (() async -> Void)?
    var preparation: (() async -> Bool)?
    let opening = ExternallyReleasedWait<Void>()
    let opened = ExternallyReleasedWait<AgentBridgeClient>()
    let attached = ExternallyReleasedWait<Void>()
    var event: (@Sendable (AgentBridgeFrame) async throws -> Void)?
    var closedClients: [UUID] = []

    func start() -> Task<Void, Never> {
        let captured = key, token = UUID()
        owner = token
        return Task { @MainActor in
            await AgentTimelineStreamRunner(timeline: state, key: captured, owner: token,
                currentKey: { self.key }, isOwner: { self.owner == token },
                metadata: {
                    self.metadataReads += 1
                    await self.metadataHook?()
                    return self.recorded
                }, publish: { self.published.append($0) },
                prepare: { await self.preparation?() ?? false },
                open: {
                    self.openCount += 1; self.event = $0
                    self.phases.append(self.state.phase); self.opening.release(())
                    return try await self.opened.wait()
                }, attach: { _ in self.attached.release(()) },
                acceptedEvent: { self.phases.append(self.state.phase) },
                close: { self.closedClients.append($0.id); await $0.close() },
                finish: { if self.owner == token { self.owner = nil }; self.phases.append(self.state.phase) }
            ).run()
        }
    }
    func update(active: Bool? = nil, connection: AgentTimelineConnectionState? = nil) {
        key = .init(paneId: key.paneId, agent: key.agent, connection: connection ?? key.connection,
                    isActive: active ?? key.isActive, retry: key.retry + 1)
    }
    static func snapshot() throws -> AgentBridgeFrame {
        try AgentBridgeFrame.decode(Data(#"{"event":"timeline.snapshot","epoch":"e","seq":1,"data":{"identity":{"pane_id":"p1","terminal_id":"t","agent":"claude","native_session_id":"s"},"generation":1,"entries":[{"id":"m","kind":"message","text":"verified","role":"assistant","truncated":false}]}}"#.utf8))
    }
    static func client() -> AgentBridgeClient { AgentBridgeClient(write: { _ in }, close: {}, onEvent: { _ in }) }
}

private actor RetirementModelWire {
    let initialize = ExternallyReleasedWait<String>()
    let watch = ExternallyReleasedWait<String>()
    private(set) var controlRequests = 0
    func write(_ data: Data) throws {
        let request = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let id = try #require(request?["id"] as? String)
        switch request?["method"] as? String {
        case "initialize": initialize.release(id)
        case "watch": watch.release(id)
        default: controlRequests += 1; throw AgentBridgeError.closed
        }
    }
    static func connected() async throws -> (AgentBridgeClient, RetirementModelWire) {
        let wire = RetirementModelWire()
        let client = AgentBridgeClient(write: { try await wire.write($0) }, close: {}, onEvent: { _ in })
        let handshake = Task { try await client.performHandshakeAndWatch(paneId: "p1") }
        let id = try await wire.initialize.wait()
        await client.receive(Data("{\"id\":\"\(id)\",\"result\":{\"protocol\":1,\"epoch\":\"e\",\"bridge_version\":\"99.0.0\",\"capabilities\":{\"claude_timeline\":true,\"model_control\":true,\"record_content\":true}}}\n".utf8))
        let watch = try await wire.watch.wait()
        await client.receive(Data("{\"id\":\"\(watch)\",\"result\":{}}\n".utf8))
        try await handshake.value
        return (client, wire)
    }
}

extension AgentTimelineConnectionTests {
    @Test func retirementDisconnectsModelControlsBeforeReplacementSnapshot() async throws {
        for path in ["begin", "retire", "end"] {
            let state = AgentTimelineState(), owner = UUID()
            state.begin(owner: owner, paneId: "p1")
            let (client, wire) = try await RetirementModelWire.connected()
            state.modelControl.connect(client, supported: true)
            try state.consume(TimelineRunHarness.snapshot(), owner: owner)
            #expect(state.modelControl.isVisible)
            let replacement = UUID()
            switch path {
            case "begin": state.begin(owner: replacement, paneId: "p1")
            case "retire": state.retire(owner: owner)
            default: state.end(owner: owner, error: .closed)
            }
            #expect(!state.modelControl.supported, "Retirement path: \(path)")
            if path != "begin" { state.begin(owner: replacement, paneId: "p1") }
            try state.consume(TimelineRunHarness.snapshot(), owner: replacement)
            #expect(!state.modelControl.isVisible)
            await state.modelControl.refresh()
            #expect(!state.modelControl.isLoadingModels)
            await state.modelControl.change(model: "new")
            #expect(await wire.controlRequests == 0)
            let (newClient, newWire) = try await RetirementModelWire.connected()
            state.modelControl.connect(newClient, supported: true)
            #expect(state.modelControl.isVisible)
            await state.modelControl.refresh()
            #expect(await newWire.controlRequests == 1)
            #expect(await wire.controlRequests == 0)
            await newClient.close()
            // Detach explicitly so no test leaves a transport retained by the controller.
            state.retire(owner: replacement)
            await client.close()
        }
    }

    @Test func currentHandshakeFailurePublishesFreshMetadataBeforeFailure() async throws {
        for code in ["pi_bridge_required", "agy_bridge_required", "cursor_bridge_required"] {
            let h = TimelineRunHarness(), task = h.start()
            try await h.opening.wait()
            #expect(h.state.phase == .loading)
            h.recorded = .init(capabilities: .init(claudeTimeline: true, codexTimeline: true, modelControl: true), version: "99.0.0")
            h.opened.fail(AgentBridgeError.unavailable(code))
            await task.value
            #expect(h.published.last?.version == "99.0.0")
            #expect(h.published.last?.capabilities?.modelControl == true)
            #expect(h.state.phase == .unavailable(code))
            let agent = code == "pi_bridge_required" ? "pi" : code == "agy_bridge_required" ? "antigravity_cli" : "cursor"
            let explanation = AgentTimelineView.explanation(code, agent: agent, installedVersion: h.published.last?.version)
            #expect(explanation.contains("directory"))
            #expect(h.phases == [.loading, .unavailable(code)])
        }
    }

    @Test func failureMetadataAwaitCannotPublishAfterRetirementOrLiveScopeChange() async throws {
        for change in ["cancel", "owner", "inactive", "connecting", "offline", "generation", "pane", "agent", "retry"] {
            let h = TimelineRunHarness(), task = h.start()
            try await h.opening.wait()
            let lookup = ExternallyReleasedWait<Void>(), release = ExternallyReleasedWait<Void>()
            h.metadataHook = { lookup.release(()); _ = try? await release.wait() }
            h.opened.fail(AgentBridgeError.unavailable("pi_bridge_required"))
            try await lookup.wait()
            #expect(h.state.phase == .loading)
            #expect(h.published.count == 1)
            let newOwner = UUID()
            switch change {
            case "cancel": task.cancel()
            case "owner":
                h.owner = newOwner
                h.state.begin(owner: newOwner, paneId: "p2", connection: h.key.connection, agent: "claude")
            case "inactive": h.update(active: false)
            case "connecting": h.update(connection: .init(phase: .connecting, generation: .init(rawValue: 1)))
            case "offline": h.update(connection: .init(phase: .offline(host: "h", username: "u"), generation: nil))
            case "generation": h.update(connection: .init(phase: h.key.connection.phase, generation: .init(rawValue: 2)))
            case "pane": h.key = .init(paneId: "p2", agent: h.key.agent, connection: h.key.connection, isActive: true, retry: 0)
            case "agent": h.key = .init(paneId: "p1", agent: "pi", connection: h.key.connection, isActive: true, retry: 0)
            default: h.update()
            }
            h.recorded = .init(capabilities: .init(claudeTimeline: true), version: "99.0.0")
            release.release(())
            await task.value
            #expect(h.published.count == 1, "No retired metadata: \(change)")
            #expect(h.state.phase == (change == "owner" ? .loading : .suspended))
            #expect(!h.phases.contains(.disconnected))
        }
    }

    @Test func queuedStaleOrCancelledRunnerCannotBeginOverCurrentReadyOwner() async throws {
        for gate in ["cancelled", "key", "owner"] {
            let h = TimelineRunHarness(), currentOwner = UUID()
            h.owner = currentOwner
            h.state.begin(owner: currentOwner, paneId: "p1", connection: h.key.connection, agent: "claude")
            try h.state.consume(TimelineRunHarness.snapshot(), owner: currentOwner)
            let identity = h.state.identity
            let captured = h.key
            if gate == "key" { h.update() }
            let runnerOwner = gate == "owner" ? UUID() : currentOwner
            var reads = 0, opens = 0
            let task = Task { @MainActor in
                if gate == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
                await AgentTimelineStreamRunner(timeline: h.state, key: captured, owner: runnerOwner,
                    currentKey: { h.key }, isOwner: { h.owner == runnerOwner },
                    metadata: { reads += 1; return .init() }, publish: { _ in },
                    open: { _ in opens += 1; throw AgentBridgeError.closed },
                    attach: { _ in }, close: { await $0.close() }).run()
            }
            await task.value
            #expect(h.state.phase == .ready, "Entry gate: \(gate)")
            #expect(h.state.identity == identity)
            #expect(h.state.entries.first?.text == "verified")
            #expect(reads == 0 && opens == 0)
            // The surviving owner must still accept its next sequence.
            let status = try AgentBridgeFrame.decode(Data(#"{"event":"timeline.updated","epoch":"e","seq":2,"data":{"identity":{"pane_id":"p1","terminal_id":"t","agent":"claude","native_session_id":"s"},"generation":1,"entries":[],"agent_status":"working"}}"#.utf8))
            try h.state.consume(status, owner: currentOwner)
            #expect(h.state.agentStatus == "working")
        }
    }

    @Test func cancellationDuringPreparationNeverOpensRetiredChannel() async throws {
        let h = TimelineRunHarness(), entered = ExternallyReleasedWait<Void>(), release = ExternallyReleasedWait<Void>()
        h.preparation = { entered.release(()); _ = try? await release.wait(); return false }
        let task = h.start()
        try await entered.wait()
        task.cancel()
        h.opened.fail(AgentBridgeError.closed)
        release.release(())
        await task.value
        #expect(h.openCount == 0)
        #expect(h.state.phase == .suspended)
        #expect(h.published.count == 1)
    }

    @Test func productionRunnerCancellationBeforeAndAfterReplacementBegins() async throws {
        for replaceFirst in [false, true] {
            let h = TimelineRunHarness(), old = h.start()
            try await h.opening.wait()
            let oldEvent = try #require(h.event)
            try await oldEvent(TimelineRunHarness.snapshot())
            #expect(h.phases == [.loading, .ready])
            if !replaceFirst { old.cancel() }
            // Use the same production store and new owner, with controlled new-open wait.
            let newOpening = ExternallyReleasedWait<Void>(), newRelease = ExternallyReleasedWait<AgentBridgeClient>()
            let newOwner = UUID()
            h.update()
            var replacement: Task<Void, Never>?
            func replace() async throws {
                h.owner = newOwner
                let key = h.key
                replacement = Task { @MainActor in
                    await AgentTimelineStreamRunner(timeline: h.state, key: key, owner: newOwner,
                        currentKey: { h.key }, isOwner: { h.owner == newOwner }, metadata: { h.recorded },
                        publish: { h.published.append($0) },
                        open: { _ in newOpening.release(()); return try await newRelease.wait() },
                        attach: { _ in }, close: { await $0.close() }).run()
                }
                try await newOpening.wait()
            }
            if replaceFirst { try await replace(); old.cancel() }
            h.opened.fail(AgentBridgeError.closed)
            await old.value
            if replaceFirst {
                #expect(h.state.phase == .loading)
            } else {
                #expect(h.state.phase == .suspended)
                try await replace()
            }
            #expect(h.state.entries.first?.text == "verified")
            #expect(h.state.phase == .loading)
            #expect(!h.phases.contains(.disconnected))
            // A queued callback from A cannot overwrite B or its metadata.
            let publications = h.published.count
            do { try await oldEvent(TimelineRunHarness.snapshot()); Issue.record("Retired event accepted") } catch {}
            #expect(h.published.count == publications)
            #expect(h.state.phase == .loading)
            replacement?.cancel(); newRelease.fail(CancellationError())
            await replacement?.value
            #expect(h.state.phase == .suspended)
        }
    }

    @Test func productionRunnerInactiveAndConnectingBecomeEligibleWithoutFailure() async throws {
        for inactive in [false, true] {
            let h = TimelineRunHarness()
            if inactive { h.update(active: false) }
            else { h.update(connection: .init(phase: .connecting, generation: .init(rawValue: 1))) }
            let first = h.start(); await first.value
            #expect(h.state.phase == .suspended)
            #expect(h.openCount == 0 && h.published.isEmpty)
            h.update(active: true, connection: .init(phase: .connected(host: "h", username: "u"), generation: .init(rawValue: 1)))
            let active = h.start(); try await h.opening.wait()
            #expect(h.state.phase == .loading)
            let event = try #require(h.event)
            try await event(TimelineRunHarness.snapshot())
            #expect(h.state.phase == .ready)
            let client = TimelineRunHarness.client()
            h.opened.release(client); try await h.attached.wait()
            active.cancel(); await active.value
            #expect(h.state.phase == .suspended)
            #expect(h.state.entries.first?.text == "verified")
            #expect(h.phases == [.suspended, .loading, .ready, .suspended])
            #expect(h.closedClients == [client.id])
        }
    }

    @Test func productionRunnerRealEOFAfterSnapshotAndOpenFailuresRemainActionable() async throws {
        for error in [AgentBridgeError.closed, .timeout, .protocolMismatch] {
            for hasSnapshot in [false, true] {
                let h = TimelineRunHarness(), task = h.start()
                try await h.opening.wait()
                if hasSnapshot { try await h.event?(TimelineRunHarness.snapshot()) }
                if hasSnapshot && error == .closed {
                    let client = TimelineRunHarness.client()
                    h.opened.release(client); try await h.attached.wait(); await client.close()
                } else { h.opened.fail(error) }
                await task.value
                let expected: AgentTimelineState.Phase = error == .closed ? .disconnected : .unavailable(error.code)
                #expect(h.state.phase == expected)
                #expect(h.phases == (hasSnapshot ? [.loading, .ready, expected] : [.loading, expected]))
                #expect(h.state.identity == nil)
            }
        }
    }
}

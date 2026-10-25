import Foundation
import Testing
@testable import Herdcats

@MainActor
@Suite("Direct SSH machine switching", .serialized)
struct MachineSwitchingTests {
    private func connected(_ model: AppModel, to config: ConnectionConfig) {
        model.connectionIdentity = ConnectionIdentity(config)
        model.phase = .connected(host: config.host, username: config.username)
        model.hasActiveSession = true
    }

    private func currentModel() -> AppModel {
        let model = AppModel(autoConnectOnLaunch: false)
        connected(model, to: ConnectionConfig(host: "current.example", port: 22,
            username: "tester", auth: .password("fixture")))
        return model
    }

    private func withConnections(
        _ body: @MainActor ([RecentConnection]) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.data(forKey: RecentConnectionStore.storageKey)
        let entries = ["b", "c"].map {
            RecentConnection(host: "\($0).example", port: 22, username: "tester",
                authMode: "password", remember: true, name: $0.uppercased())
        }
        defer {
            if let previous { defaults.set(previous, forKey: RecentConnectionStore.storageKey) }
            else { defaults.removeObject(forKey: RecentConnectionStore.storageKey) }
            for entry in entries { try? KeychainStore.delete(account: entry.secretAccount) }
        }
        defaults.set(try JSONEncoder().encode(entries), forKey: RecentConnectionStore.storageKey)
        for entry in entries { try KeychainStore.save("fixture", account: entry.secretAccount) }
        try await body(entries)
    }

    @Test func switchSwapsOnlyAfterTargetConnects() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let candidate = AppModel(autoConnectOnLaunch: false)
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            let active = ActiveMachine(model: old, makeModel: { candidate }, dial: { model, config in
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            let switching = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            #expect(active.model === old)
            #expect(old.hasActiveSession)
            #expect(active.pending === candidate)
            #expect(active.pendingLabel == "B")
            resume.release(true)
            #expect(await switching.value == .switched)
            #expect(active.model === candidate)
            #expect(!old.hasActiveSession)
            #expect(old.phase == .disconnected)
            #expect(active.pending == nil)
            #expect(active.pendingLabel == nil)
        }
    }

    @Test func failedSwitchKeepsCurrentMachine() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let candidate = AppModel(autoConnectOnLaunch: false)
            let active = ActiveMachine(model: old, makeModel: { candidate }, dial: { model, _ in
                model.lastError = "auth"
            })
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            #expect(active.model === old)
            #expect(old.hasActiveSession)
            #expect(old.phase == .connected(host: "current.example", username: "tester"))
            #expect(active.switchError == "Couldn't reach B: auth")
            #expect(active.pending == nil)
            #expect(active.pendingLabel == nil)
            #expect(candidate.phase == .disconnected)
        }
    }

    @Test func laterSelectionSupersedesEarlier() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            var candidates: [AppModel] = []
            let active = ActiveMachine(model: currentModel(), makeModel: {
                let model = AppModel(autoConnectOnLaunch: false)
                candidates.append(model)
                return model
            }, dial: { model, config in
                if config.host == entries[0].host {
                    started.release(true)
                    _ = try? await resume.wait()
                }
                self.connected(model, to: config)
            })
            let first = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            #expect(await active.switchMachine(to: entries[1]) == .switched)
            resume.release(true)
            #expect(await first.value == .superseded)
            #expect(candidates.count == 2)
            #expect(active.model === candidates[1])
            #expect(candidates[0].phase == .disconnected)
            #expect(!candidates[0].hasActiveSession)
        }
    }

    @Test func selectingSameTargetTwiceDialsOnce() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            var calls = 0
            let active = ActiveMachine(model: currentModel(), dial: { model, config in
                calls += 1
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            let first = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            #expect(await active.switchMachine(to: entries[0]) == .superseded)
            #expect(calls == 1)
            resume.release(true)
            #expect(await first.value == .switched)
        }
    }

    @Test func selectingActiveMachineIsNoOp() async {
        let old = currentModel()
        var calls = 0
        let active = ActiveMachine(model: old, dial: { _, _ in calls += 1 })
        let entry = RecentConnection(host: "current.example", port: 22, username: "tester",
            authMode: "password", remember: false)
        #expect(await active.switchMachine(to: entry) == .alreadyActive)
        #expect(calls == 0)
        #expect(active.model === old)
    }

    @Test func missingCredentialsReturnsNeedsCredentials() async {
        var calls = 0
        let active = ActiveMachine(model: currentModel(), dial: { _, _ in calls += 1 })
        var entry = RecentConnection(host: "missing.example", port: 22, username: "tester",
            authMode: "password", remember: false)
        #expect(await active.switchMachine(to: entry) == .needsCredentials)
        entry.remember = true
        #expect(await active.switchMachine(to: entry) == .needsCredentials)
        #expect(calls == 0)
        #expect(active.pending == nil)
    }

    @Test func hostKeyChallengeKeepsPendingAndCancelRestores() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let candidate = AppModel(autoConnectOnLaunch: false)
            let active = ActiveMachine(model: old, makeModel: { candidate }, dial: { model, config in
                model.hostKeyChallenge = SSHHostKeyChallenge(host: config.host, port: config.port,
                    publicKey: "fixture")
            })
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            #expect(active.pending === candidate)
            #expect(active.model === old)
            #expect(active.switchError == nil)
            await active.cancelSwitch()
            #expect(active.pending == nil)
            #expect(active.pendingLabel == nil)
            #expect(candidate.hostKeyChallenge == nil)
            #expect(active.model === old)
            #expect(old.hasActiveSession)
            #expect(await active.finishPendingSwitch() == .superseded)
        }
    }

    @Test func hostKeyApprovalThenFinishSwitches() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let candidate = AppModel(autoConnectOnLaunch: false)
            var calls = 0
            let active = ActiveMachine(model: old, makeModel: { candidate }, dial: { model, config in
                calls += 1
                if calls == 1 {
                    model.hostKeyChallenge = SSHHostKeyChallenge(host: config.host, port: config.port,
                        publicKey: "fixture")
                } else {
                    self.connected(model, to: config)
                }
            })
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            // The existing approval sheet clears the challenge before calling finish.
            candidate.hostKeyChallenge = nil
            #expect(await active.finishPendingSwitch() == .switched)
            #expect(calls == 2)
            #expect(active.model === candidate)
            #expect(!old.hasActiveSession)
            #expect(active.pending == nil)
        }
    }

    @Test func successfulSwitchStampsLastConnected() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let active = ActiveMachine(model: currentModel(), dial: { model, config in
                self.connected(model, to: config)
            })
            #expect(await active.switchMachine(to: entries[1]) == .switched)
            let saved = try RecentConnectionStore.load()
            #expect(saved.map(\.id) == entries.map(\.id))
            #expect(saved[0].lastConnectedAt == nil)
            #expect(saved[1].lastConnectedAt != nil)
        }
    }

    @Test func newerSelectionSupersedesHostKeyFinish() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            var calls = 0
            let active = ActiveMachine(model: currentModel(), dial: { model, config in
                calls += 1
                if calls == 1 {
                    model.hostKeyChallenge = SSHHostKeyChallenge(host: config.host, port: config.port,
                        publicKey: "fixture")
                    return
                }
                if config.host == entries[0].host {
                    started.release(true)
                    _ = try? await resume.wait()
                }
                self.connected(model, to: config)
            })
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            let first = try #require(active.pending)
            first.hostKeyChallenge = nil
            let finishing = Task { await active.finishPendingSwitch() }
            _ = try await started.wait()
            #expect(await active.switchMachine(to: entries[1]) == .switched)
            resume.release(true)
            #expect(await finishing.value == .superseded)
            #expect(first.phase == .disconnected)
            #expect(active.model.connectionIdentity?.host == entries[1].host)
        }
    }
}

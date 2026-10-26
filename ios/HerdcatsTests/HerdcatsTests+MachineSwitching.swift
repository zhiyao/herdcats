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

    @Test func rejectedCandidateRetainsSignInRecoveryAfterTeardown() async throws {
        try await withConnections { entries in
            let old = currentModel()
            // Recovery must follow the failed candidate, not the connected machine.
            old.lastConnectPassphraseRejected = true
            var rejectPassphrase = false
            let active = ActiveMachine(model: old, dial: { model, _ in
                model.lastError = "Authentication rejected"
                model.lastConnectNeedsSignIn = true
                model.lastConnectPassphraseRejected = rejectPassphrase
            })
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            #expect(active.pending == nil)
            #expect(active.model === old)
            #expect(active.signInFailure == .init(needsSignIn: true, passphraseRejected: false))
            rejectPassphrase = true
            #expect(await active.switchMachine(to: entries[0]) == .failed)
            #expect(active.signInFailure == .init(needsSignIn: true, passphraseRejected: true))
            await active.cancelSwitch()
            #expect(active.signInFailure == nil)
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

    @Test func selectingMachineWithoutCredentialsCancelsPendingSwitch() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            let old = currentModel()
            let active = ActiveMachine(model: old, dial: { model, config in
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            let first = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            let locked = RecentConnection(host: "locked.example", port: 22, username: "tester",
                authMode: "password", remember: false)
            #expect(await active.switchMachine(to: locked) == .needsCredentials)
            #expect(active.pending == nil)
            resume.release(true)
            #expect(await first.value == .superseded)
            #expect(active.model === old)
        }
    }

    @Test func selectingActiveMachineCancelsPendingSwitch() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            var calls = 0
            let old = currentModel()
            let active = ActiveMachine(model: old, dial: { model, config in
                calls += 1
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            let first = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            let current = RecentConnection(host: "current.example", port: 22, username: "tester",
                authMode: "password", remember: true)
            #expect(await active.switchMachine(to: current) == .alreadyActive)
            #expect(active.pending == nil)
            resume.release(true)
            #expect(await first.value == .superseded)
            #expect(active.model === old)
            #expect(calls == 1)
        }
    }

    @Test func sessionSubtreeSurvivesFailedReconnectButNotSwitch() {
        let model = currentModel()
        let before = MainTabView.subtreeID(for: model)
        model.connectionIdentity = nil
        model.phase = .offline(host: "current.example", username: "tester")
        #expect(MainTabView.subtreeID(for: model) == before)
        #expect(MainTabView.subtreeID(for: currentModel()) != before)
    }

    @Test func disconnectCancelsPendingSwitch() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            let old = currentModel()
            let active = ActiveMachine(model: old, dial: { model, config in
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            let first = Task { await active.switchMachine(to: entries[0]) }
            _ = try await started.wait()
            await active.disconnect()
            #expect(active.pending == nil)
            #expect(!old.hasActiveSession)
            resume.release(true)
            #expect(await first.value == .superseded)
            #expect(active.model === old)
            #expect(!active.model.hasActiveSession)
        }
    }

    @Test func switchWithExplicitConfigSkipsKeychain() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            var entry = entries[0]
            entry.remember = false
            try KeychainStore.delete(account: entry.secretAccount)
            let config = ConnectionConfig(host: entry.host, port: entry.port,
                username: entry.username, auth: .password("typed-secret"))
            var received: ConnectionConfig?
            let old = currentModel()
            let active = ActiveMachine(model: old, dial: { model, config in
                received = config
                self.connected(model, to: config)
            })
            #expect(await active.switchMachine(to: entry, config: config) == .switched)
            #expect(received == config)
            #expect(!old.hasActiveSession)
        }
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


extension MachineSwitchingTests {
    @Test func menuSignInSwitchKeepsCurrentUntilConnected() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let started = ExternallyReleasedWait<Bool>()
            let resume = ExternallyReleasedWait<Bool>()
            let active = ActiveMachine(model: old, dial: { model, config in
                started.release(true)
                _ = try? await resume.wait()
                self.connected(model, to: config)
            })
            try KeychainStore.delete(account: entries[0].secretAccount)
            #expect(await active.switchMachine(to: entries[0]) == .needsCredentials)
            let signIn = ConnectionSignIn(entry: entries[0], secret: "typed-password")
            let switching = Task { try await active.signIn(using: signIn) }
            _ = try await started.wait()
            #expect(active.model === old)
            #expect(old.hasActiveSession)
            #expect(try KeychainStore.load(account: entries[0].secretAccount) == nil)
            resume.release(true)
            #expect(try await switching.value == .switched)
            #expect(active.model !== old)
            #expect(!old.hasActiveSession)
            #expect(try KeychainStore.load(account: entries[0].secretAccount) == "typed-password")
            #expect(try RecentConnectionStore.load().first?.lastConnectedAt != nil)
        }
    }

    @Test func switchThenPersistKeepsFreshTimestamp() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let active = ActiveMachine(model: currentModel(), dial: { model, config in self.connected(model, to: config) })
            #expect(await active.switchMachine(to: entries[1]) == .switched)
            let switched = try RecentConnectionStore.load()
            let stamp = try #require(switched[1].lastConnectedAt)
            try ConnectionSignIn(entry: entries[1], secret: "replacement").persist(connected: false)
            let saved = try RecentConnectionStore.load()
            #expect(saved.map(\.id) == entries.map(\.id))
            #expect(saved[1].lastConnectedAt == stamp)
            #expect(saved[1].name == entries[1].name)
        }
    }

    @Test func menuSignInHostTrustPersistsOnlyAfterApprovedSwitch() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            var calls = 0
            let active = ActiveMachine(model: old, dial: { model, config in
                calls += 1
                if calls == 1 {
                    model.hostKeyChallenge = SSHHostKeyChallenge(host: config.host, port: config.port, publicKey: "fixture")
                } else { self.connected(model, to: config) }
            })
            let signIn = ConnectionSignIn(entry: entries[0], secret: "replacement")
            #expect(try await active.signIn(using: signIn) == .failed)
            #expect(active.model === old)
            #expect(try KeychainStore.load(account: entries[0].secretAccount) == "fixture")
            let pending = try #require(active.pending)
            pending.hostKeyChallenge = nil
            #expect(try await active.finishSignIn(using: signIn) == .switched)
            #expect(try KeychainStore.load(account: entries[0].secretAccount) == "replacement")
            #expect(try RecentConnectionStore.load().first?.lastConnectedAt != nil)
        }
    }

    @Test func menuSignInCancelKeepsCurrentAndSavedCredentials() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            let old = currentModel()
            let active = ActiveMachine(model: old, dial: { model, config in
                model.hostKeyChallenge = SSHHostKeyChallenge(host: config.host, port: config.port, publicKey: "fixture")
            })
            let signIn = ConnectionSignIn(entry: entries[0], secret: "replacement")
            #expect(try await active.signIn(using: signIn) == .failed)
            await active.cancelSwitch()
            #expect(active.model === old)
            #expect(old.hasActiveSession)
            #expect(try await active.finishSignIn(using: signIn) == .superseded)
            #expect(try KeychainStore.load(account: entries[0].secretAccount) == "fixture")
        }
    }
}


extension MachineSwitchingTests {
    @Test func replayMenuSignInDoesNotStampOrSaveCredentials() async throws {
        try await withConnections { (entries: [RecentConnection]) async throws in
            struct PendingFixture: Encodable {
                let sourceAccount: String
                let entry: RecentConnection
            }
            let key = "hc.pendingCredentialMigration"
            let previousPending = UserDefaults.standard.data(forKey: key)
            let source = "test.replay-migration.\(UUID())"
            defer {
                if let previousPending { UserDefaults.standard.set(previousPending, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
                try? KeychainStore.delete(account: source)
            }
            let active = ActiveMachine(model: currentModel(), dial: { model, config in self.connected(model, to: config) })
            try KeychainStore.save("fixture", account: source)
            let marker = try JSONEncoder().encode(PendingFixture(sourceAccount: source, entry: entries[0]))
            UserDefaults.standard.set(marker, forKey: key)
            let before = UserDefaults.standard.data(forKey: RecentConnectionStore.storageKey)
            let signIn = ConnectionSignIn(entry: entries[0], secret: "replay secret")
            #expect(try await active.signIn(using: signIn, replay: true) == .switched)
            #expect(UserDefaults.standard.data(forKey: RecentConnectionStore.storageKey) == before)
            #expect(UserDefaults.standard.data(forKey: key) == marker)
            #expect(try KeychainStore.load(account: source, readOnly: true) == "fixture")
            #expect(try KeychainStore.load(account: entries[0].secretAccount, readOnly: true) == "fixture")
        }
    }
}

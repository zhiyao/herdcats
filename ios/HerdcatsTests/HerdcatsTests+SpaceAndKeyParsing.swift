import Crypto
import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Space join and status ranking")
struct SpaceJoinTests {
    @Test
    func joinsAgentsIntoSpacesAndSortsByNumber() throws {
        let workspaces = try HerdrConnection.decode(workspaceListJSON, as: WorkspaceListResult.self).workspaces
        let agents = try HerdrConnection.decode(agentListJSON, as: AgentListResult.self).agents

        let spaces = Space.join(workspaces: workspaces, agents: agents)
        #expect(spaces.map(\.workspace.number) == [1, 2, 3])

        let herdrcat = try #require(spaces.first { $0.id == "w4H" })
        #expect(herdrcat.agents.count == 1)
        #expect(herdrcat.agents.first?.agent == "pi")
        // lone working agent -> working
        #expect(herdrcat.status == .working)

        let samplenotes = try #require(spaces.first { $0.id == "w4" })
        // idle + blocked -> blocked is more attention-worthy
        #expect(samplenotes.status == .blocked)

        let samplemedia = try #require(spaces.first { $0.id == "w32" })
        // No agents: falls back to the workspace-level status
        #expect(samplemedia.status == .idle)
    }

    @Test
    func statusRankingMatchesHerdrAttentionPriority() {
        // Same order herdr uses for its priority agent panel and workspace
        // rollup: blocked > done > working > idle > unknown.
        #expect(AgentStatus.blocked.attentionPriority > AgentStatus.done.attentionPriority)
        #expect(AgentStatus.done.attentionPriority > AgentStatus.working.attentionPriority)
        #expect(AgentStatus.working.attentionPriority > AgentStatus.idle.attentionPriority)
        #expect(AgentStatus.idle.attentionPriority > AgentStatus.unknown.attentionPriority)
    }

    @Test
    func priorityOrderingRanksSpaceGroupsLikeAgents() throws {
        let workspaces = try HerdrConnection.decode(workspaceListJSON, as: WorkspaceListResult.self).workspaces
        let agents = try HerdrConnection.decode(agentListJSON, as: AgentListResult.self).agents
        let groups = SpaceGroup.group(Space.join(workspaces: workspaces, agents: agents))

        #expect(groups.sorted(by: SpaceGroup.attentionOrder).map(\.root.id) == ["w4", "w4H", "w32"])
    }
}

// MARK: - Space grouping

@Suite("Space creation presentation")
struct SpaceCreationPresentationTests {
    @Test func showsCreatedWorkspaceUntilRefreshAndNeverDuplicatesIt() {
        let created = Workspace(
            workspaceId: "created",
            label: "New space",
            number: 2,
            tabCount: 1,
            paneCount: 1,
            activeTabId: "tab-created",
            agentStatus: "idle",
            focused: false,
            worktree: nil
        )
        let existing = Workspace(
            workspaceId: "existing",
            label: "Existing space",
            number: 1,
            tabCount: 1,
            paneCount: 1,
            activeTabId: "tab-existing",
            agentStatus: "idle",
            focused: false,
            worktree: nil
        )
        let listed = Space.join(workspaces: [existing], agents: [])
        let unconfirmed = Space(workspace: created, agents: [])
        #expect(SpacePresentationOverlay.visibleSpaces([], unconfirmed: [unconfirmed]).map(\.id) == ["created"])
        #expect(SpaceGroup.group(SpacePresentationOverlay.visibleSpaces(listed, unconfirmed: [unconfirmed]))
            .map(\.root.id) == ["existing", "created"])

        let refreshed = Space.join(workspaces: [existing, created], agents: [])
        #expect(SpacePresentationOverlay.visibleSpaces(refreshed, unconfirmed: [unconfirmed]).map(\.id)
            == ["existing", "created"])
        #expect(SpacePresentationOverlay.unconfirmed([unconfirmed], after: refreshed).isEmpty)
    }
}

@Suite("Worktree presentation")
struct WorktreePresentationTests {
    @Test func returnedWorkspaceWithoutWorktreeMetadataStaysUnderItsSourceCard() {
        let sourceWorkspace = Workspace(
            workspaceId: "root",
            label: "Repository",
            number: 1,
            tabCount: 1,
            paneCount: 1,
            activeTabId: "root-tab",
            agentStatus: "idle",
            focused: false,
            worktree: Worktree(
                checkoutPath: "/repo",
                repoName: "repo",
                repoRoot: "/repo",
                isLinkedWorktree: false
            )
        )
        let machine = SpaceMachine(
            scope: ConnectionIdentity(host: "example.test", port: 22, username: "tester"),
            label: "Test machine",
            order: 0
        )
        let source = Space(workspace: sourceWorkspace, agents: [], machine: machine)
        let returnedWorkspace = Workspace(
            workspaceId: "linked",
            label: "Feature",
            number: 2,
            tabCount: 1,
            paneCount: 1,
            activeTabId: "linked-tab",
            agentStatus: "idle",
            focused: false,
            worktree: nil
        )
        let entry = WorktreeEntry(
            path: "/repo-feature",
            branch: "feature",
            label: nil,
            isBare: false,
            isDetached: false,
            isLinkedWorktree: true,
            isPrunable: false,
            openWorkspaceId: "linked"
        )
        let presented = WorktreePresentation.space(returnedWorkspace, entry: entry, source: source)
        #expect(presented.machine == machine && presented.workspace.worktree?.repoRoot == "/repo")
        let groups = SpaceGroup.group(SpacePresentationOverlay.visibleSpaces([source], unconfirmed: [presented]))
        #expect(groups.count == 1)
        #expect(groups[0].worktrees.map(\.id) == [presented.id])
        #expect(SpacePresentationOverlay.visibleSpaces([source, presented], unconfirmed: [presented]).count == 2)
        #expect(SpacePresentationOverlay.unconfirmed([presented], after: [source, presented]).isEmpty)
    }

    @Test func pendingTitlesReflectTheChosenAction() {
        #expect(PendingWorktreeAction.openTitle(path: "/repo/feature", branch: nil)
            == "Opening worktree “feature”…")
        #expect(PendingWorktreeAction.createTitle(name: nil, label: nil) == "Creating worktree…")
        #expect(PendingWorktreeAction.createTitle(name: "feature", label: "My Feature")
            == "Creating worktree “My Feature”…")
    }
}

@Suite("Space grouping by repo root")
struct SpaceGroupTests {
    func groupsFromFixture() throws -> [SpaceGroup] {
        let workspaces = try HerdrConnection
            .decode(workspaceListWithWorktreesJSON, as: WorkspaceListResult.self)
            .workspaces
        return SpaceGroup.group(Space.join(workspaces: workspaces, agents: []))
    }

    @Test
    func foldsLinkedWorktreesUnderTheirRoot() throws {
        let groups = try groupsFromFixture()

        // Roots and standalone spaces only — linked worktrees never get a card.
        #expect(groups.map(\.root.id) == ["w4", "w32", "w35", "w4C"])

        let samplenotes = try #require(groups.first { $0.root.id == "w4" })
        #expect(samplenotes.worktrees.map(\.id) == ["w36", "w48"])

        let sampleshop = try #require(groups.first { $0.root.id == "w35" })
        #expect(sampleshop.worktrees.map(\.id) == ["w3W"])

        // No worktree — stays standalone.
        let samplemedia = try #require(groups.first { $0.root.id == "w32" })
        #expect(samplemedia.worktrees.isEmpty)
    }

    @Test
    func promotesFirstLinkedWorktreeWhenNoRootExists() throws {
        let groups = try groupsFromFixture()

        // Only linked worktrees exist for the orphan repo — the first becomes
        // the card so the group is still visible.
        let orphan = try #require(groups.first { $0.root.id == "w4C" })
        #expect(orphan.worktrees.map(\.id) == ["w4E"])
    }

    @Test
    func groupStatusAggregatesAcrossWorktrees() throws {
        let groups = try groupsFromFixture()

        // samplenotes: idle root + blocked linked worktree -> blocked.
        let samplenotes = try #require(groups.first { $0.root.id == "w4" })
        #expect(samplenotes.status == .blocked)

        // sampleshop: idle root + working linked worktree -> working, and
        // focus inside a worktree highlights the whole group.
        let sampleshop = try #require(groups.first { $0.root.id == "w35" })
        #expect(sampleshop.status == .working)
        #expect(sampleshop.isFocused == true)
        #expect(samplenotes.isFocused == false)
    }
}

// MARK: - OpenSSH key parsing

@Suite("OpenSSH ed25519 key parsing")
struct OpenSSHKeyParserTests {
    /// Throwaway key generated for this test suite only.
    private static let unencryptedPEM = OpenSSHParserFixture.pem

    private static let encrypted16 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCbXkJg7L
    Fx6WjNp/Gz9nRnAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIJL3ixoEfPqABvBN
    wlMfi4z+ckv1WNZQo00MhyOR1nIEAAAAoOncXPrbrVC9rQnwN68X6PY3tzllHQb96vnoLf
    nKt7e66Trh4TFW5j0hkPJyt0euwiyYbQo9sS9jw9bPtNhcRzIevywyKo1MYrbxZ34KQW/J
    CTRpH1sDxVQii5mP8bCmyoJ3xcrzaWgID97uA9YovHU7rEBmqjMH8pmDZCXOtw/KPYLGlp
    5lBqqP/9o4oCfWXFaP1V8ZT+jolVYSNdUC0TQ=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let encrypted32 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBY0sytrK
    GA6SISkuAEnnY6AAAAIAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIHrV7DrXLWaVn6j
    JCmh4T6LOtDY4KVB7FL4OXJl34hhAAAAoCRsT/xm/r8VwGQqwE+I5AfBc7uwR5QlC2L+ld
    d5H54B7lFod3Qbw7OfySl30hTx0TvKznw30MI+Cz9SSkNmji/piPRFs4F1tPACwqTQiI25
    jopJD5XKlYHQ+FkVWctVQkLuS1qC+qAoa39ln/lcrMY2H6V7Qyj/EMe3uIrmbAGYM4CkbG
    lbLQp51lgCG/Pc4See3yz8SBbXIXbpkppdWls=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let encrypted64 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABBQsNNQDE
    3OeNlbiirYuF51AAAAQAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIEHiHx4Brcpqh9OW
    lY7YKkM3HN1yOFbJNYbUClrT7q+MAAAAoPXvIQDoTJK/XrKBIF2kuCD9KIPYTstdeLIEcI
    heoaAWhTJoeN0uixLdLK2E0qnaOA4teelJmrqntGC3kaWAOknVv7UPGceybXd82nYykl/s
    xiPxdhHmIcm/mO6Bw1Cve9cJZF6k2sd0EBzfwnaFImLcSF3oL/T6Cf/JS6vTFOWHjh+anc
    1Jzhj402WYisxnyveuTPZGidiF24UyVUEMyEs=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let encryptedFullPadding = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABA67fmC6c588ccWKTA+gjakAAAAIAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGQrPTgKc2Tjmng/nP1vdbdEG1R97z6O8gsc+bO1lHoWAAAAoHplRLWrpysjRVDkBaZSvn+5etGE2KV7W0HRbLtyHkB+ikdsAD0xhIbdIzeV31ckY055SDLBqiUb9oOQbzAxrHlcdc2ydF/nWc/vv/VckXWwDxCqIbr+8dxqt0aZ0FNNwtbpiEcorhvhz1KET+O0lqVWSrMhAU0l26S0PoqtFWOFnJKyZ8Vxu/EFNhOJJHpX4Ks7Giyw1bVlMi3xrN8lrhI=
    -----END OPENSSH PRIVATE KEY-----
    """
    private static let encrypted256 = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAACmFlczEyOC1jdHIAAAAGYmNyeXB0AAAAGAAAABCAZBE4rD
    GCia9qfNiUzHkCAAABAAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIMTvWynpLNkXUBjf
    Nf4cZ/jd18DuIsMlR5uS8EQWsvaOAAAAoJVICIyrMT/au68JOgwscoUFx6QeumnNNjtcRA
    MIOVoTAAYhUf5MN0bWqGex1L4SHUko9OuekkCPnXK83G/cc/yeThLoxtZQehdJZO/v25fV
    8135ra4Q4lu7diODsZEQNnTK/WXA/M5C4zk77QNwjp16RElsKf5vaq2F740JYGqAC3BroD
    uRbhBLh+7+GeZBW+mZQSBsmKIG72CzaFiCR4o=
    -----END OPENSSH PRIVATE KEY-----
    """
    @Test
    func parsesUnencryptedEd25519Key() throws {
        let raw = try OpenSSHEd25519.parseRawPrivateKey(pem: Self.unencryptedPEM)
        // CryptoKit exposes the 32-byte ed25519 seed.
        #expect(raw.count == 32)

        // The embedded public key must match the known fixture public key
        // (authorized_keys blob: "ssh-ed25519" string + 32 raw bytes).
        let blob = Data(base64Encoded: OpenSSHParserFixture.publicKeyLine.split(separator: " ").last.map(String.init) ?? "")
        #expect(blob?.count == 51)
        #expect(try OpenSSHEd25519.parsePublicKey(pem: Self.unencryptedPEM) == blob?.suffix(32))
    }

    @Test
    func unlocksEncryptedKeysAboveOldRoundLimit() throws {
        for pem in [Self.encrypted16, Self.encrypted32, Self.encrypted64, Self.encrypted256, Self.encryptedFullPadding] {
            #expect(try OpenSSHEd25519.isEncrypted(pem: pem))
            let raw = try OpenSSHEd25519.parseRawPrivateKey(pem: pem, passphrase: "herdcats-test-passphrase")
            #expect(raw.count == 32)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
            #expect(key.publicKey.rawRepresentation == (try OpenSSHEd25519.parsePublicKey(pem: pem)))
            #expect(throws: OpenSSHKeyError.passphraseRequired) {
                _ = try OpenSSHEd25519.parseRawPrivateKey(pem: pem)
            }
            #expect(throws: OpenSSHKeyError.invalidPassphraseOrKey) {
                _ = try OpenSSHEd25519.parseRawPrivateKey(pem: pem, passphrase: "wrong")
            }
        }
    }

    @Test
    func rejectsCorruptedFinalPaddingByte() throws {
        let body = Self.encryptedFullPadding.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var bytes = try #require(Data(base64Encoded: body))
        bytes[bytes.count - 1] ^= 1
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + bytes.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----"
        #expect(throws: OpenSSHKeyError.invalidPassphraseOrKey) {
            _ = try OpenSSHEd25519.parseRawPrivateKey(pem: pem, passphrase: "herdcats-test-passphrase")
        }
    }

    @MainActor
    @Test
    func keyUnlockFailureDoesNotRetryAutomatically() {
        #expect(AppModel.connectFailureDisposition(error: OpenSSHKeyError.passphraseRequired,
            hadActiveSession: true, wasOffline: true, isCheckingHerdr: false) == .disconnected)
    }

    @MainActor
    @Test
    func launchRequiresRememberedPassphraseForEncryptedKey() throws {
        let suite = "EncryptedKeyLaunch.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LaunchPreference.autoConnect.rawValue, forKey: LaunchPreference.storageKey)
        let entry = RecentConnectionStore.entry(host: "test.example", port: 22, username: "tester",
            authMode: "privateKey", remember: true, in: [])
        _ = try RecentConnectionStore.record(entry, in: [], defaults: defaults)
        let keychain = FakeKeychainOperations()
        keychain.items[entry.secretAccount] = Data(Self.encrypted64.utf8)
        #expect(LaunchPreference.autoConnectConfig(defaults: defaults, keychain: keychain) == nil)
        keychain.items[entry.secretAccount + ".passphrase"] = Data("herdcats-test-passphrase".utf8)
        let config = try #require(LaunchPreference.autoConnectConfig(defaults: defaults, keychain: keychain))
        guard case let .privateKey(pem, passphrase) = config.auth else {
            Issue.record("Expected private key authentication")
            return
        }
        #expect(pem == Self.encrypted64)
        #expect(passphrase == "herdcats-test-passphrase")
        keychain.items[entry.secretAccount] = Data(Self.unencryptedPEM.utf8)
        keychain.items.removeValue(forKey: entry.secretAccount + ".passphrase")
        #expect(LaunchPreference.autoConnectConfig(defaults: defaults, keychain: keychain) != nil)
    }

    @Test
    func rejectsExcessiveWorkBeforeDecryption() throws {
        let body = Self.encrypted64.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var bytes = try #require(Data(base64Encoded: body))
        // magic, cipher string, KDF string, options length, salt string, rounds
        var offset = 15
        func length(at index: Int) -> Int {
            bytes[index..<(index + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        offset += 4 + length(at: offset)
        offset += 4 + length(at: offset)
        offset += 4
        offset += 4 + length(at: offset)
        bytes.replaceSubrange(offset..<(offset + 4), with: [0, 0, 1, 1])
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + bytes.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----"
        #expect(throws: OpenSSHKeyError.excessiveRounds) {
            _ = try OpenSSHEd25519.parseRawPrivateKey(pem: pem, passphrase: "herdcats-test-passphrase")
        }
    }

    @Test
    func rejectsGarbage() {
        #expect(throws: OpenSSHKeyError.self) {
            _ = try OpenSSHEd25519.parseRawPrivateKey(pem: "not a key at all")
        }
    }

    @Test
    func formatsOpenSSHPublicKeyStringAndFingerprint() throws {
        let pubKeyString = try OpenSSHEd25519.parseOpenSSHPublicKeyString(pem: Self.unencryptedPEM)
        #expect(pubKeyString == OpenSSHParserFixture.publicKeyLine)

        let fingerprint = try OpenSSHEd25519.parseFingerprint(pem: Self.unencryptedPEM)
        #expect(fingerprint == SSHHostKeyValidatorDelegate.fingerprint(pubKeyString))
        #expect(fingerprint.hasPrefix("SHA256:"))
    }

    @Test
    func masksPrivateKeyPreservingOnlyLastTwoLines() {
        #expect(OpenSSHEd25519.maskPrivateKey(pem: "") == "")

        let masked = OpenSSHEd25519.maskPrivateKey(pem: Self.unencryptedPEM)
        let lines = masked.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "••••••••••••••••••••••••••••••••")
        #expect(lines[1] == "••••••••••••••••••••••••••••••••")
        #expect(lines[2] == String(Self.unencryptedPEM.split(separator: "\n").dropLast().last!))
        #expect(lines[3] == "-----END OPENSSH PRIVATE KEY-----")

        #expect(!masked.contains("BEGIN OPENSSH PRIVATE KEY"))
        #expect(!masked.contains("b3BlbnNzaC1rZXktdjE"))

        let twoLines = "line1\nline2"
        #expect(OpenSSHEd25519.maskPrivateKey(pem: twoLines) == "••••••••••••••••••••••••••••••••\nline1\nline2")
    }
}

@Suite("Long dictation")
struct DictationTranscriptTests {
    @Test func pauseWithoutTaskFinalKeepsEverySentence() {
        var transcript = DictationTranscript(committed: "Existing draft.")
        let ended1 = transcript.receive("First sent", isFinal: false)
        #expect(!ended1)
        let ended2 = transcript.receive("First sentence.", isFinal: false, speechDuration: 1.8)
        #expect(ended2)
        let ended3 = transcript.receive("Second", isFinal: false)
        #expect(!ended3)
        #expect(transcript.text == "Existing draft. First sentence. Second")
        let ended4 = transcript.receive("Second sentence.", isFinal: false, speechDuration: 2.1)
        #expect(ended4)
        let ended5 = transcript.receive("Third sentence.", isFinal: true)
        #expect(ended5)
        #expect(transcript.text == "Existing draft. First sentence. Second sentence. Third sentence.")
    }

    @Test func unfinishedHypothesesCanStillBeCorrected() {
        var transcript = DictationTranscript()
        let ended6 = transcript.receive("Send it on Monday", isFinal: false, speechDuration: 0)
        #expect(!ended6)
        let ended7 = transcript.receive("Send it on Tuesday", isFinal: false)
        #expect(!ended7)
        let ended8 = transcript.receive("Send it on Tuesday.", isFinal: false, speechDuration: 2)
        #expect(ended8)
        #expect(transcript.text == "Send it on Tuesday.")
        let ended9 = transcript.receive("Send it on Tuesday.", isFinal: true)
        #expect(ended9)
        // Repeating the same sentence in the next request is real speech, not a duplicate.
        #expect(transcript.text == "Send it on Tuesday. Send it on Tuesday.")
    }

    @Test func emptyFinalCallbackPreservesLastRecognizedWords() {
        var transcript = DictationTranscript()
        let ended10 = transcript.receive("Keep the last words", isFinal: false)
        #expect(!ended10)
        let ended11 = transcript.receive("", isFinal: true)
        #expect(ended11)
        #expect(transcript.text == "Keep the last words")
    }

    @Test func preservesDraftAndEarlierSegmentsWhenPartialResultsChange() {
        var transcript = DictationTranscript(committed: "Existing draft.")
        transcript.update("First incomplete")
        transcript.update("First sentence.")
        transcript.commit()
        transcript.update("Second")
        transcript.update("Second sentence.")
        #expect(transcript.text == "Existing draft. First sentence. Second sentence.")
        transcript.commit()
        #expect(transcript.text == "Existing draft. First sentence. Second sentence.")
    }

    @Test func preservesAllTextAcrossManyRecognitionSessions() {
        var transcript = DictationTranscript()
        let segments = (1...100).map { "Sentence \($0)." }
        for segment in segments {
            transcript.update(segment)
            transcript.commit()
        }
        #expect(transcript.text == segments.joined(separator: " "))
    }

    @Test func emptySegmentsAndExistingWhitespaceDoNotDuplicateText() {
        var transcript = DictationTranscript(committed: "Draft\n")
        transcript.commit()
        transcript.update("More words.")
        transcript.commit()
        transcript.commit()
        #expect(transcript.text == "Draft\nMore words.")
    }
}

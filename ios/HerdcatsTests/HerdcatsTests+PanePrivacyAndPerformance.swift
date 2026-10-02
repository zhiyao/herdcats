import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@MainActor
@Suite("Pane content privacy")
struct PaneContentPrivacyTests {
    func withStore(_ body: (UserDefaults, PaneContentPersistence) -> Void) {
        let suite = "PaneContentPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults, PaneContentPersistence(defaults: defaults))
    }

    @Test func savingDefaultsToEnabledAndLoadsExistingText() {
        withStore { defaults, store in
            defaults.set("draft", forKey: "pane-draft.legacy")
            defaults.set(PaneCommandHistory.encode(["sent"]), forKey: "pane-history.legacy")
            #expect(store.isEnabled)
            #expect(store.loadDraft(key: "pane-draft.legacy") == "draft")
            #expect(store.loadHistory(key: "pane-history.legacy") == ["sent"])
        }
    }

    @Test func disablingErasesAllContentAndPreservesOtherPreferences() {
        withStore { defaults, store in
            let contentKeys = ["pane-draft.legacy", "pane-draft.legacy.remote",
                               "pane-history.legacy", "pane-draft.machine-a.pane",
                               "pane-history.machine-b.pane"]
            let otherKeys = ["pane-last-updated.pane", "recent-connections", "appearance"]
            for key in contentKeys + otherKeys { defaults.set("fixture", forKey: key) }
            store.setEnabled(false)
            #expect(!store.isEnabled)
            for key in contentKeys { #expect(defaults.object(forKey: key) == nil) }
            for key in otherKeys { #expect(defaults.string(forKey: key) == "fixture") }
            #expect(!store.saveDraft("new", key: contentKeys[0], revision: store.revision))
            #expect(!store.record("sent", key: "pane-history.legacy", revision: store.revision))
            #expect(store.loadDraft(key: contentKeys[0]).isEmpty)
            #expect(store.loadHistory(key: "pane-history.legacy").isEmpty)
            #expect(!PaneContentPersistence(defaults: defaults).isEnabled)
        }
    }

    @Test func clearRejectsCachedDraftsAndDelayedSendCompletions() {
        withStore { defaults, store in
            let beforeClear = store.revision
            #expect(store.saveDraft("old", key: "pane-draft.a", revision: beforeClear))
            store.eraseSavedContent()
            #expect(store.isEnabled)
            #expect(!store.saveDraft("old", key: "pane-draft.a", revision: beforeClear))
            #expect(!store.saveDraft("remote old", key: "pane-draft.a.remote", revision: beforeClear))
            #expect(!store.record("delayed send", key: "pane-history.a", revision: beforeClear))
            #expect(defaults.object(forKey: "pane-history.a") == nil)
            #expect(store.saveDraft("fresh", key: "pane-draft.a", revision: store.revision))
            #expect(store.loadDraft(key: "pane-draft.a") == "fresh")
            #expect(store.saveDraft("", key: "pane-draft.a", revision: store.revision))
            #expect(defaults.object(forKey: "pane-draft.a") == nil)
        }
    }

    @Test func reenablingCannotRestoreEarlierText() {
        withStore { _, store in
            let enabledRevision = store.revision
            store.setEnabled(false)
            let disabledRevision = store.revision
            store.eraseSavedContent()
            #expect(!store.isEnabled)
            store.setEnabled(true)
            for revision in [enabledRevision, disabledRevision] {
                #expect(!store.saveDraft("stale", key: "pane-draft.a", revision: revision))
                #expect(!store.record("stale", key: "pane-history.a", revision: revision))
            }
            #expect(store.loadHistory(key: "pane-history.a").isEmpty)
            #expect(store.record("fresh", key: "pane-history.a", revision: store.revision))
            #expect(store.loadHistory(key: "pane-history.a") == ["fresh"])
        }
    }

    @Test func savedHistoryRetainsDeduplicationAndLimit() {
        withStore { _, store in
            for index in 0..<60 {
                store.record("message-\(index)", key: "pane-history.a", revision: store.revision)
            }
            store.record(" message-58 ", key: "pane-history.a", revision: store.revision)
            let history = store.loadHistory(key: "pane-history.a")
            #expect(history.count == 50)
            #expect(history.first == "message-58")
            #expect(Set(history).count == 50)
            #expect(!store.record("  ", key: "pane-history.a", revision: store.revision))
        }
    }
}

@Suite("Performance and encoding optimizations")
struct PerformanceOptimizationTests {
    @Test func imageEncoderDownscalesLargeImagesInSinglePass() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500))
        let largeImage = renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let encoded = PaneImageEncoder.encode(largeImage, prefersPNG: false)
        #expect(encoded != nil)
        if let encoded {
            #expect(encoded.preview.size.width <= 2048)
            #expect(encoded.preview.size.height <= 2048)
            #expect(encoded.preview.size.width == 2048)
            #expect(encoded.preview.size.height == 1024)
            #expect(!encoded.data.isEmpty)
        }
    }

    @Test func ansiLinesChunkNewlineHandling() {
        let raw = "\u{1B}[32mLine 1\nLine 2\nLine 3\u{1B}[0m\nLine 4"
        let lines = ANSIText.lines(from: raw)
        #expect(lines.count == 4)
        #expect(lines.map(\.plain) == ["Line 1", "Line 2", "Line 3", "Line 4"])
    }

    /// Swift treats CRLF as one Character; rows must still split.
    @Test func ansiLinesSplitCRLFSeparatedRows() {
        let lines = ANSIText.lines(from: "\u{1B}[32mfirst\u{1B}[0m\r\nsecond\r\n\r\nfourth")
        #expect(lines.map(\.plain) == ["first", "second", "", "fourth"])
    }
}

@Suite("Connection friendly error messages")
struct FriendlyErrorMessageTests {
    private static let testKeyPEM = OpenSSHParserFixture.pem

    @Test
    func privateKeyAuthenticationFailureIncludesPublicKeyAndGuidance() {
        struct MockAuthError: Error, CustomStringConvertible {
            var description: String { "allAuthenticationOptionsFailed" }
        }

        let config = ConnectionConfig(
            host: "myhost.local",
            port: 22,
            username: "testuser",
            auth: .privateKey(Self.testKeyPEM)
        )

        let message = HerdrConnection.friendlyMessage(for: MockAuthError(), config: config)
        #expect(message.contains("Authentication failed for user 'testuser' at myhost.local"))
        #expect(message.contains(OpenSSHParserFixture.publicKeyLine))
        #expect(message.contains("~/.ssh/authorized_keys"))
    }

    @Test
    func passwordAuthenticationFailureMentionsPassword() {
        struct MockAuthError: Error, CustomStringConvertible {
            var description: String { "allAuthenticationOptionsFailed" }
        }

        let config = ConnectionConfig(
            host: "myhost.local",
            port: 22,
            username: "testuser",
            auth: .password("secret")
        )

        let message = HerdrConnection.friendlyMessage(for: MockAuthError(), config: config)
        #expect(message.contains("Authentication failed for user 'testuser' at myhost.local"))
        #expect(message.contains("password"))
    }

    @Test
    func openSSHKeyErrorReturnsLocalizedDescription() {
        let message = HerdrConnection.friendlyMessage(for: OpenSSHKeyError.missingPEMBody)
        #expect(message.contains("No OPENSSH PRIVATE KEY block found"))
    }
}

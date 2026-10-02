import Foundation
import Testing
@testable import Herdcats

@Suite("Quota unavailable cards")
struct QuotaUnavailableTests {
    /// quota-axi aggregate report where Claude's Keychain read failed while
    /// Codex stayed healthy (the shape behind the raw `keychain_access_…` card).
    private let keychainFailureJSON = """
    {
      "providers": [
        {
          "provider": "claude",
          "windows": [],
          "state": { "status": "error", "stale": false, "error": "keychain_access_denied" }
        },
        {
          "provider": "codex",
          "windows": [
            { "id": "weekly", "label": "week", "kind": "weekly", "percentRemaining": 42 }
          ],
          "state": { "status": "fresh", "stale": false }
        }
      ]
    }
    """

    private let healthyClaudeJSON = """
    {
      "providers": [
        {
          "provider": "claude",
          "windows": [
            { "id": "five_hour", "kind": "session", "percentRemaining": 7 },
            { "id": "seven_day", "kind": "weekly", "percentRemaining": 9 }
          ],
          "state": { "status": "fresh", "stale": false }
        }
      ]
    }
    """

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Every string the card puts on screen or reads to VoiceOver.
    private func visibleStrings(_ card: AgentUsageCard) -> [String] {
        var strings = [card.displayTitle, card.accessibilityLabel(now: now)]
        if let state = card.unavailableState {
            strings.append(state.title)
            strings.append(contentsOf: [state.detail].compactMap { $0 })
        } else {
            for chip in card.ringOrderedChips.prefix(2) {
                strings.append(chip.percentText)
                strings.append(chip.displayLabel(now: now))
            }
        }
        return strings
    }

    @Test func keychainErrorRendersUnavailableStateWithoutRawText() throws {
        let cards = try QuotaReport.decode(keychainFailureJSON).usageCards()
        let claude = try #require(cards.first { $0.provider == "claude" })
        #expect(!claude.isAvailable)
        #expect(claude.unavailableState == .unavailable)
        #expect(claude.unavailableState?.title == "Quota unavailable")
        #expect(claude.unavailableState?.canRetry == true)
        for card in cards {
            for text in visibleStrings(card) {
                #expect(!text.localizedCaseInsensitiveContains("keychain"), "\(card.provider): \(text)")
            }
        }

        let codex = try #require(cards.first { $0.provider == "codex" })
        #expect(codex.isAvailable)
        #expect(codex.unavailableState == nil)
        #expect(codex.chips.map(\.percentRemaining) == [42])
    }

    @Test func otherRemoteErrorsNeverShowRawText() {
        let errors = [
            "keychain_prompt_required", "keychain_unreachable", "fetch failed",
            "Antigravity CLI: connection failed", "HTTP 500 {\"error\":\"internal\"}"
        ]
        for error in errors {
            for provider in ["claude", "agy", "zai"] {
                let card = AgentUsageCard(provider: provider, chips: [], unavailableReason: error)
                #expect(card.unavailableState == .unavailable)
                let label = card.accessibilityLabel(now: now)
                #expect(!label.contains(error))
                #expect(label.hasSuffix("quota unavailable"))
            }
        }
    }

    @Test func knownReasonsKeepTheirFriendlyStates() throws {
        let signIn = AgentUsageCard(provider: "agy", chips: [], unavailableReason: "Antigravity sign-in required")
        #expect(signIn.unavailableState == .signInRequired)
        let auth = AgentUsageCard(provider: "claude", chips: [], unavailableReason: "Sign-in required")
        #expect(auth.unavailableState?.title == "Sign in")
        let offline = AgentUsageCard(provider: "agy", chips: [], unavailableReason: "port discovery failed")
        #expect(offline.unavailableState == .cliOffline)

        var report = try QuotaReport.decode(#"{"providers":[]}"#)
        report.cliVersion = "0.1.12"
        let missing = try #require(report.usageCards().first { $0.provider == "zai" })
        #expect(missing.unavailableState == .notReported(cliVersion: "0.1.12"))
        #expect(missing.unavailableState?.detail == "quota-axi 0.1.12")
        #expect(missing.unavailableState?.canRetry == true)
    }

    @Test func healthyPayloadKeepsRingsAndPercentages() throws {
        let cards = try QuotaReport.decode(healthyClaudeJSON).usageCards()
        let claude = try #require(cards.first { $0.provider == "claude" })
        #expect(claude.isAvailable)
        #expect(claude.unavailableState == nil)
        #expect(claude.ringOrderedChips.map(\.percentText) == ["9%", "7%"])
        #expect(claude.accessibilityLabel(now: now) == "Claude: 9 percent left, week; 7 percent left, 5h")
    }

    @Test func zeroPercentIsQuotaNotMissingData() throws {
        let json = """
        {"providers":[{"provider":"claude","windows":[
          {"id":"five_hour","kind":"session","percentRemaining":0},
          {"id":"seven_day","kind":"weekly","percentRemaining":0.0}
        ],"state":{"status":"fresh"}}]}
        """
        let claude = try #require(QuotaReport.decode(json).usageCards().first { $0.provider == "claude" })
        #expect(claude.isAvailable)
        #expect(claude.unavailableState == nil)
        #expect(claude.chips.map(\.percentRemaining) == [0, 0])
    }

    @MainActor
    @Test func retryRerunsOnlyThatProviderAndRestoresItsRings() async throws {
        let model = SpacesModel()
        model.applyUsageReport(try QuotaReport.decode(keychainFailureJSON))
        let order = model.usageCards.map(\.provider)

        var requested: [String] = []
        let healthy = try QuotaReport.decode(healthyClaudeJSON)
        await model.retryUsage(provider: "claude") { provider in
            requested.append(provider)
            return healthy
        }

        #expect(requested == ["claude"])
        #expect(model.usageCards.map(\.provider) == order)
        let claude = try #require(model.usageCards.first { $0.provider == "claude" })
        #expect(claude.isAvailable)
        #expect(claude.chips.map(\.percentRemaining) == [7, 9])
        let codex = try #require(model.usageCards.first { $0.provider == "codex" })
        #expect(codex.chips.map(\.percentRemaining) == [42])
        #expect(model.retryingUsageProviders.isEmpty)
    }

    @MainActor
    @Test func failedRetryKeepsFriendlyUnavailableState() async throws {
        let model = SpacesModel()
        model.applyUsageReport(try QuotaReport.decode(keychainFailureJSON))
        await model.retryUsage(provider: "claude") { _ in
            throw HerdrError.unexpectedResponse("keychain_access_denied")
        }
        let claude = try #require(model.usageCards.first { $0.provider == "claude" })
        #expect(claude.unavailableState == .unavailable)
        #expect(claude.displayUnavailableReason == "keychain_access_denied")
        #expect(!claude.accessibilityLabel(now: now).contains("keychain"))
        #expect(model.retryingUsageProviders.isEmpty)

        var missingReport = try QuotaReport.decode(#"{"providers":[]}"#)
        missingReport.cliVersion = "0.1.12"
        model.applyUsageReport(missingReport)
        await model.retryUsage(provider: "claude") { _ in
            throw HerdrError.unexpectedResponse("fetch failed")
        }
        let missing = try #require(model.usageCards.first { $0.provider == "claude" })
        #expect(missing.unavailableState == .notReported(cliVersion: "0.1.12"))
    }

    @Test func providerErrorWithRetainedWindowsStaysUnavailable() throws {
        let json = """
        {"providers":[
          {"provider":"claude","windows":[{"id":"seven_day","kind":"weekly","percentRemaining":42}],
           "state":{"status":"error","error":"keychain_access_denied"}},
          {"provider":"agy","windows":[
            {"id":"gemini_weekly","kind":"weekly","percentRemaining":60},
            {"id":"claude_gpt_weekly","kind":"weekly","percentRemaining":40}
          ],"state":{"status":"error","error":"keychain_access_denied"}}
        ]}
        """
        let cards = try QuotaReport.decode(json).usageCards()
        for id in ["claude", "agy", "agy-claude"] {
            let card = try #require(cards.first { $0.provider == id })
            #expect(!card.isAvailable)
            #expect(card.unavailableState == .unavailable)
            #expect(card.unavailableState?.canRetry == true)
            #expect(card.chips.isEmpty)
        }
    }

    @MainActor
    @Test func agyClaudeCardRetriesTheAgyProvider() async throws {
        let failing = """
        {"providers":[{"provider":"agy","windows":[],"state":{"error":"Antigravity CLI: offline"}}]}
        """
        let healthy = """
        {"providers":[{"provider":"agy","windows":[
          {"id":"gemini_5h","kind":"session","percentRemaining":80},
          {"id":"gemini_weekly","kind":"weekly","percentRemaining":60},
          {"id":"claude_gpt_5h","kind":"session","percentRemaining":50},
          {"id":"claude_gpt_weekly","kind":"weekly","percentRemaining":40}
        ]}]}
        """
        let model = SpacesModel()
        model.applyUsageReport(try QuotaReport.decode(failing))
        let agy = try #require(model.usageCards.first { $0.provider == "agy" })
        #expect(agy.quotaProviderID == "agy")
        #expect(AgentUsageCard(provider: "agy-claude", chips: [], unavailableReason: nil).quotaProviderID == "agy")

        var requested: [String] = []
        await model.retryUsage(provider: agy.quotaProviderID) { provider in
            requested.append(provider)
            return try QuotaReport.decode(healthy)
        }
        #expect(requested == ["agy"])
        #expect(model.usageCards.map(\.provider) == ["cursor", "codex", "claude", "agy", "agy-claude", "zai"])
        #expect(model.usageCards.first { $0.provider == "agy-claude" }?.chips.map(\.percentRemaining) == [50, 40])
    }

    @Test func providerScopedCommandQuotesTheProviderID() {
        let script = HerdrConnection.quotaAxiRemoteScript(provider: "claude")
        #expect(script.contains("--provider \(HerdrConnection.shellSafeArgument("claude")) --json"))
        #expect(!HerdrConnection.quotaAxiRemoteScript.contains("--provider"))
    }
}

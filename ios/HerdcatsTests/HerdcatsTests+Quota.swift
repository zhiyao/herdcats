import Foundation
import Security
import NIOSSH
import SwiftUI
import Testing
@testable import Herdcats

@Suite("Quota axi")
struct QuotaAxiTests {
    private let sampleJSON = """
    {
      "generatedAt": "2026-09-20T13:24:21.854Z",
      "schemaVersion": 5,
      "providers": [
        {
          "provider": "claude",
          "plan": "pro",
          "windows": [
            {
              "id": "five_hour",
              "label": "session",
              "kind": "session",
              "resetsAt": "2026-09-20T14:00:00.243513+00:00",
              "percentRemaining": 94
            },
            {
              "id": "seven_day",
              "label": "week",
              "kind": "weekly",
              "resetsAt": "2026-09-22T00:59:59.243534+00:00",
              "percentRemaining": 29
            }
          ],
          "state": { "status": "fresh", "stale": false }
        },
        {
          "provider": "codex",
          "plan": "prolite",
          "windows": [
            {
              "id": "weekly",
              "label": "week",
              "kind": "weekly",
              "resetsAt": "2026-09-26T08:14:57.000Z",
              "percentRemaining": 91
            }
          ],
          "state": { "status": "fresh", "stale": false }
        },
        {
          "provider": "cursor",
          "plan": "Pro",
          "windows": [
            {
              "id": "included_usage",
              "label": "included usage",
              "kind": "monthly",
              "resetsAt": "2026-10-20T07:33:40.000Z",
              "percentRemaining": 99
            },
            {
              "id": "api_usage",
              "label": "API usage",
              "kind": "monthly",
              "resetsAt": "2026-10-20T07:33:40.000Z",
              "percentRemaining": 100
            }
          ],
          "state": { "status": "fresh", "stale": false }
        },
        {
          "provider": "agy",
          "label": "Antigravity",
          "windows": [
            {
              "id": "gemini_5h",
              "label": "Gemini 5-hour",
              "kind": "session",
              "resetsAt": "2026-09-20T19:14:39.000Z",
              "percentRemaining": 100
            },
            {
              "id": "gemini_weekly",
              "label": "Gemini weekly",
              "kind": "weekly",
              "resetsAt": "2026-09-23T02:23:57.000Z",
              "percentRemaining": 41
            },
            {
              "id": "claude_gpt_5h",
              "label": "Claude/GPT 5-hour",
              "kind": "session",
              "resetsAt": "2026-09-20T19:14:39.000Z",
              "percentRemaining": 100
            },
            {
              "id": "claude_gpt_weekly",
              "label": "Claude/GPT weekly",
              "kind": "weekly",
              "resetsAt": "2026-09-27T14:14:39.000Z",
              "percentRemaining": 100
            }
          ],
          "state": { "status": "fresh", "stale": false }
        },
        {
          "provider": "zai",
          "plan": "pro",
          "windows": [
            {
              "id": "mcp_month",
              "label": "MCP month",
              "kind": "monthly",
              "resetsAt": "2026-09-30T10:31:19.979Z",
              "percentRemaining": 99
            },
            {
              "id": "five_hour",
              "label": "session",
              "kind": "session",
              "resetsAt": "2026-09-20T18:54:47.092Z",
              "percentRemaining": 99
            },
            {
              "id": "weekly",
              "label": "week",
              "kind": "weekly",
              "resetsAt": "2026-09-25T10:12:06.984Z",
              "percentRemaining": 81
            }
          ],
          "state": { "status": "fresh", "stale": false }
        },
        {
          "provider": "copilot",
          "windows": [],
          "state": {
            "status": "auth_required",
            "stale": false,
            "error": "GitHub Copilot sign-in required"
          }
        }
      ]
    }
    """

    @Test func decodesProviderWindowsAndProjectsHeaderCards() throws {
        let report = try QuotaReport.decode(sampleJSON)
        #expect(report.providers.count == 6)

        let cards = report.usageCards()
        // Primaries always appear; other auth_required providers stay hidden.
        #expect(cards.map(\.provider) == ["cursor", "codex", "claude", "agy", "agy-claude", "zai"])

        let cursor = try #require(cards.first { $0.provider == "cursor" })
        #expect(cursor.chips.map(\.id) == ["included_usage"])
        #expect(cursor.chips.map(\.label) == ["all"])
        #expect(cursor.chips.map(\.percentRemaining) == [99])

        let codex = try #require(cards.first { $0.provider == "codex" })
        #expect(codex.chips.map(\.label) == ["week"])
        #expect(codex.chips.map(\.percentRemaining) == [91])

        let claude = try #require(cards.first { $0.provider == "claude" })
        #expect(claude.chips.map(\.label) == ["5h", "week"])
        #expect(claude.chips.map(\.percentRemaining) == [94, 29])

        let agy = try #require(cards.first { $0.provider == "agy" })
        #expect(agy.chips.map(\.label) == ["G5h", "Gwk"])
        #expect(agy.chips.map(\.percentRemaining) == [100, 41])

        let agyC = try #require(cards.first { $0.provider == "agy-claude" })
        #expect(agyC.chips.map(\.label) == ["C5h", "Cwk"])
        #expect(agyC.chips.map(\.percentRemaining) == [100, 100])

        let zai = try #require(cards.first { $0.provider == "zai" })
        #expect(zai.chips.map(\.label) == ["5h", "week"])
        #expect(zai.chips.map(\.percentRemaining) == [99, 81])
        #expect(!zai.chips.contains { $0.id == "mcp_month" })

        #expect(cards.contains { $0.provider == "copilot" } == false)
    }

    @Test func weeklyChipShowsDaysUntilResetBeyond48Hours() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let chip = AgentUsageChip(
            id: "seven_day", label: "week", percentRemaining: 50,
            resetsAt: now.addingTimeInterval(4 * 86_400 + 5 * 3600)
        )
        #expect(chip.displayLabel(now: now) == "4d left")
    }

    @Test func countdownChipShowsHoursThenMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func label(hoursAhead: Double) -> String {
            AgentUsageChip(
                id: "weekly", label: "week", percentRemaining: 50,
                resetsAt: now.addingTimeInterval(hoursAhead * 3600)
            ).displayLabel(now: now)
        }
        #expect(label(hoursAhead: 48) == "2d left")
        #expect(label(hoursAhead: 47.9) == "47h left")
        #expect(label(hoursAhead: 5.5) == "5h left")
        #expect(label(hoursAhead: 1) == "1h left")
        #expect(label(hoursAhead: 0.5) == "30m left")
        #expect(label(hoursAhead: 0.001) == "1m left")
        #expect(label(hoursAhead: -1) == "week")
    }

    @Test func everyDatedChipShowsCountdownAndUndatedKeepsLabel() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3 * 86_400)
        #expect(AgentUsageChip(id: "gemini_weekly", label: "Gwk", percentRemaining: 10, resetsAt: reset)
            .displayLabel(now: now) == "3d left")
        #expect(AgentUsageChip(id: "mcp_month", label: "mcp", percentRemaining: 10, resetsAt: reset)
            .displayLabel(now: now) == "3d left")
        #expect(AgentUsageChip(id: "weekly", label: "week", percentRemaining: 10, resetsAt: nil)
            .displayLabel(now: now) == "week")
    }

    @Test func fullQuotaIsAlwaysOnPaceColor() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let scheduled = AgentUsageChip(
            id: "weekly", label: "week", percentRemaining: 100,
            resetsAt: now.addingTimeInterval(86_400), windowDuration: 7 * 86_400
        )
        let unscheduled = AgentUsageChip(id: "weekly", label: "week", percentRemaining: 100, resetsAt: nil)
        for chip in [scheduled, unscheduled] {
            #expect(Theme.quotaColor(for: chip, now: now) == Theme.successGreen)
            #expect(Theme.quotaColor(for: chip, now: now, inner: true) == Theme.successGreen)
        }
    }

}

@Suite("Quota axi remote errors and CLI")
struct QuotaAxiRemoteTests {
    @Test func agyRemoteErrorOmitsRedundantCLIPrefix() throws {
        let json = """
        {"providers":[{"provider":"agy","windows":[],
          "state":{"status":"error","error":"Antigravity CLI: connection failed"}}]}
        """
        let card = try #require(QuotaReport.decode(json).usageCards().first { $0.provider == "agy" })
        #expect(card.displayUnavailableReason == "connection failed")
        #expect(card.unavailableReason == "Antigravity CLI: connection failed")
        #expect(!card.isAvailable)

        let prefixOnly = AgentUsageCard(provider: "agy", chips: [], unavailableReason: "Antigravity CLI")
        #expect(prefixOnly.displayUnavailableReason == "Unavailable")
        let lowercased = AgentUsageCard(provider: "agy", chips: [], unavailableReason: "antigravity cli — offline")
        #expect(lowercased.displayUnavailableReason == "offline")
        let other = AgentUsageCard(provider: "codex", chips: [], unavailableReason: "Antigravity CLI: offline")
        #expect(other.displayUnavailableReason == other.unavailableReason)
    }

    @Test func alwaysShowsAgyEvenWhenAuthRequired() throws {
        let json = """
        {
          "providers": [
            {
              "provider": "agy",
              "windows": [],
              "state": {
                "status": "auth_required",
                "error": "Antigravity sign-in required"
              }
            }
          ]
        }
        """
        let cards = try QuotaReport.decode(json).usageCards()
        #expect(cards.map(\.provider) == ["cursor", "codex", "claude", "agy", "zai"])
        let agy = try #require(cards.first { $0.provider == "agy" })
        #expect(!agy.isAvailable)
        #expect(agy.unavailableReason?.contains("sign-in") == true)
    }

    @Test func interpretQuotaAxiRecognizesMissingBinaryAndStripsPrefix() throws {
        #expect(throws: HerdrError.quotaAxiNotFound) {
            try HerdrConnection.interpretQuotaAxi(HerdrConnection.quotaAxiNotFoundMarker)
        }

        let wrapped = "noise\n{\"generatedAt\":\"x\",\"providers\":[]}"
        let json = try HerdrConnection.interpretQuotaAxi(wrapped)
        #expect(json.hasPrefix("{"))
        let report = try QuotaReport.decode(json)
        #expect(report.providers.isEmpty)
    }

    @Test func quotaAxiRemoteCommandProbesCommonPaths() throws {
        let script = HerdrConnection.quotaAxiRemoteScript
        #expect(script.contains("quota-axi"))
        #expect(script.contains("--json"))
        #expect(script.contains("--no-credential-refresh"))
        #expect(script.contains(HerdrConnection.quotaAxiNotFoundMarker))
        #expect(!script.contains("// Prefer"))
        #expect(!script.contains("`agy`"))
        #expect(script.contains("$HOME/.local/bin:"))
        #expect(script.contains("mise/shims"))
        let localBinRange = script.range(of: "$HOME/.local/bin:")
        let localBin = try #require(localBinRange)
        let miseRange = script.range(of: "mise/shims")
        let mise = try #require(miseRange)
        #expect(localBin.lowerBound < mise.lowerBound)

        let command = HerdrConnection.quotaAxiRemoteCommand()
        #expect(command.hasPrefix("exec /bin/sh -c "))
        #expect(command.contains("printf"))
    }

    @Test func interpretQuotaAxiOutputKeepsVersionAndStripsItsLine() throws {
        let json = #"{"generatedAt":"x","providers":[]}"#
        let wrapped = "\(HerdrConnection.quotaAxiVersionPrefix)0.1.47\n\(json)"
        let output = try HerdrConnection.interpretQuotaAxiOutput(wrapped)
        #expect(output.version == "0.1.47")
        #expect(output.json == json)
        #expect(try HerdrConnection.interpretQuotaAxi(wrapped) == json)

        let noVersion = try HerdrConnection.interpretQuotaAxiOutput(json)
        #expect(noVersion.version == nil)
        #expect(noVersion.json == json)
    }

    @Test func missingProviderCardNamesTheRemoteCLIVersion() throws {
        var report = try QuotaReport.decode(#"{"providers":[]}"#)
        report.cliVersion = "0.1.12"
        let agy = try #require(report.usageCards().first { $0.provider == "agy" })
        #expect(agy.unavailableReason == "Not reported by quota-axi 0.1.12")

        report.cliVersion = nil
        let withoutVersion = try #require(report.usageCards().first { $0.provider == "agy" })
        #expect(withoutVersion.unavailableReason == "Not reported by quota-axi")
    }

    @Test func antigravityProviderIDMapsOntoTheAgyCard() throws {
        let json = """
        {
          "providers": [
            {
              "provider": "antigravity",
              "windows": [
                { "id": "gemini_5h", "kind": "session", "percentRemaining": 84 },
                { "id": "gemini_weekly", "kind": "weekly", "percentRemaining": 38 }
              ],
              "state": { "status": "fresh" }
            }
          ]
        }
        """
        let cards = try QuotaReport.decode(json).usageCards()
        let agy = try #require(cards.first { $0.provider == "agy" })
        #expect(agy.isAvailable)
        #expect(agy.chips.map(\.label) == ["G5h", "Gwk"])
        #expect(agy.chips.map(\.percentRemaining) == [84, 38])
        #expect(cards.filter { $0.provider == "agy" }.count == 1)
    }

    @Test func quotaAxiScriptReportsVersionAndWidensPath() throws {
        let script = HerdrConnection.quotaAxiRemoteScript
        #expect(script.contains(HerdrConnection.quotaAxiVersionPrefix))
        #expect(script.contains("--version"))
        // Login-shell PATH so CLIs quota-axi shells out to (agy) resolve.
        #expect(script.contains("$SHELL\" -lc"))
        #expect(script.contains("antigravity/bin"))
    }

    @Test func interpretQuotaAxiRecoversJSONAfterExitMarker() throws {
        let json = #"{"generatedAt":"x","providers":[]}"#
        let wrapped = "\(HerdrConnection.exitMarkerPrefix)1\n\(json)"
        let recovered = try HerdrConnection.interpretQuotaAxi(wrapped)
        #expect(recovered == json)
    }

    @Test func quotaAxiNotSetupViewProperties() {
        #expect(QuotaAxiNotSetupView.setupGuideURL.scheme == "https")
        #expect(QuotaAxiNotSetupView.setupGuideURL.host == "github.com")
        #expect(QuotaAxiNotSetupView.setupGuideURL.path.contains("quota-axi"))
        #expect(QuotaAxiNotSetupView.setupGuideURL.fragment == "quick-start")
        #expect(QuotaAxiNotSetupView.installCommand == "npm i -g quota-axi")
    }

    @MainActor
    @Test func spacesModelTracksQuotaAxiMissingState() throws {
        let model = SpacesModel()
        #expect(!model.quotaAxiMissing)
        #expect(model.usageCards.isEmpty)

        let healthyJSON = #"{"providers":[]}"#
        model.applyUsageReport(try QuotaReport.decode(healthyJSON))
        #expect(!model.quotaAxiMissing)
    }
}

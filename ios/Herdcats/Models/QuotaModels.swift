import Foundation

// MARK: - quota-axi JSON

/// Snapshot returned by `quota-axi --json` on the Herdr machine.
struct QuotaReport: Decodable, Equatable, Sendable {
    var generatedAt: String?
    var schemaVersion: Int?
    var providers: [QuotaProvider]
    /// Version string reported by the remote CLI (not part of the JSON payload).
    var cliVersion: String?

    enum CodingKeys: String, CodingKey {
        case generatedAt, schemaVersion, providers
    }

    static func decode(_ output: String) throws -> QuotaReport {
        guard let data = output.data(using: .utf8) else {
            throw HerdrError.unexpectedResponse("quota-axi output was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(QuotaReport.self, from: data)
        } catch {
            throw HerdrError.unexpectedResponse("quota-axi JSON: \(error)")
        }
    }
}

struct QuotaProvider: Decodable, Equatable, Sendable {
    var provider: String
    var plan: String?
    var label: String?
    var windows: [QuotaWindow]
    var state: QuotaProviderState?
}

struct QuotaProviderState: Decodable, Equatable, Sendable {
    var status: String?
    var stale: Bool?
    var error: String?
}

struct QuotaWindow: Decodable, Equatable, Sendable {
    var id: String
    var label: String?
    var kind: String?
    var resetsAt: String?
    /// Remaining percentage in the window (0–100). Decoded from Int or Double.
    var percentRemaining: Double?

    enum CodingKeys: String, CodingKey {
        case id, label, kind, resetsAt, percentRemaining
    }

    init(
        id: String,
        label: String? = nil,
        kind: String? = nil,
        resetsAt: String? = nil,
        percentRemaining: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.resetsAt = resetsAt
        self.percentRemaining = percentRemaining
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        if let value = try container.decodeIfPresent(Double.self, forKey: .percentRemaining) {
            percentRemaining = value
        } else if let value = try container.decodeIfPresent(Int.self, forKey: .percentRemaining) {
            percentRemaining = Double(value)
        } else {
            percentRemaining = nil
        }
    }
}

// MARK: - Display projection

/// One provider card for the Agents usage header.
struct AgentUsageCard: Identifiable, Equatable, Sendable {
    let provider: String
    let chips: [AgentUsageChip]
    let unavailableReason: String?

    var id: String { provider }

    var isAvailable: Bool { unavailableReason == nil && !chips.isEmpty }

    /// The card title already identifies Agy; keep the remote error's useful detail.
    var displayUnavailableReason: String? {
        guard provider == "agy", let unavailableReason else { return unavailableReason }
        let reason = unavailableReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = reason.range(of: "Antigravity CLI", options: [.anchored, .caseInsensitive]) else {
            return unavailableReason
        }
        let detail = reason[prefix.upperBound...].trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-–—"))
        )
        return detail.isEmpty ? "Unavailable" : detail
    }
}

struct AgentUsageChip: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let percentRemaining: Int
    let resetsAt: Date?
    /// Total duration of this quota window, used to compute the linear burn-rate
    /// reference point. `nil` when the window type is not time-bounded.
    var windowDuration: TimeInterval?

    var percentText: String { "\(percentRemaining)%" }

    /// Label shown under the percent: time until reset in whole days, hours
    /// once fewer than 48h remain, then minutes in the final hour. Falls back
    /// to the window name when the reset time is unknown or already passed.
    func displayLabel(now: Date = .now) -> String {
        guard let resetsAt, resetsAt > now else { return label }
        let minutes = Int(resetsAt.timeIntervalSince(now) / 60)
        let hours = minutes / 60
        if hours >= 48 { return "\(hours / 24)d left" }
        if hours >= 1 { return "\(hours)h left" }
        return "\(max(minutes, 1))m left"
    }

    /// Expected percentage remaining at `now` assuming a flat linear burn rate.
    /// Returns `nil` when `resetsAt` or `windowDuration` is unavailable.
    func expectedPercentRemaining(now: Date = .now) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let timeLeft = resetsAt.timeIntervalSince(now)
        guard timeLeft > 0 else { return 0 }
        return min(100, max(0, (timeLeft / windowDuration) * 100))
    }

    /// True when remaining quota is below the linear burn-rate reference.
    /// Equivalent to "at the burn rate so far, this runs out before it resets".
    func isBehindPace(now: Date = .now) -> Bool {
        guard let expected = expectedPercentRemaining(now: now) else { return false }
        return Double(percentRemaining) < expected
    }

    /// Projected percentage left when the window resets, extrapolating the
    /// burn rate so far. Negative when the quota runs out first. `nil` when
    /// `resetsAt` or `windowDuration` is unavailable.
    func projectedPercentAtReset(now: Date = .now) -> Double? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let timeLeft = max(0, resetsAt.timeIntervalSince(now))
        let elapsed = windowDuration - timeLeft
        let remaining = Double(percentRemaining)
        guard elapsed > 0 else { return remaining }
        return remaining - (100 - remaining) / elapsed * timeLeft
    }

    /// Seconds until 0% at the burn rate so far. `nil` when nothing has been
    /// used yet or the window has no known schedule.
    func secondsUntilEmpty(now: Date = .now) -> TimeInterval? {
        guard let resetsAt, let windowDuration, windowDuration > 0 else { return nil }
        let elapsed = windowDuration - max(0, resetsAt.timeIntervalSince(now))
        let used = 100 - Double(percentRemaining)
        guard elapsed > 0, used > 0 else { return nil }
        return Double(percentRemaining) / (used / elapsed)
    }
}

extension AgentUsageCard {
    /// Sort key for "Runs out first": windows that run out before reset come
    /// first (soonest empty first), then the rest by least projected quota at
    /// reset, then windows without a schedule by percent left. Unavailable
    /// cards sort last.
    func depletionRank(now: Date = .now) -> (tier: Int, value: Double) {
        guard isAvailable else { return (3, 0) }
        return chips.map { chip -> (tier: Int, value: Double) in
            if chip.isBehindPace(now: now), let empty = chip.secondsUntilEmpty(now: now) {
                return (0, empty)
            }
            if let projected = chip.projectedPercentAtReset(now: now) {
                return (1, max(0, projected))
            }
            return (2, Double(chip.percentRemaining))
        }
        .min { ($0.tier, $0.value) < ($1.tier, $1.value) } ?? (3, 0)
    }

    /// Chips ordered for the rings: the longest window (e.g. weekly) is the
    /// outer ring, shorter windows (e.g. 5h) sit inside. Chips without a known
    /// duration keep their order at the end.
    var ringOrderedChips: [AgentUsageChip] {
        chips.enumerated().sorted { lhs, rhs in
            switch (lhs.element.windowDuration, rhs.element.windowDuration) {
            case let (l?, r?) where l != r: return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }
}

extension QuotaReport {
    /// Preferred Agents-header order (matches quota-axi's provider list).
    /// Agy sits with the primary coding agents so it is not buried past ZAI.
    static let headerProviders = [
        "cursor", "codex", "claude", "agy", "agy-claude", "zai", "copilot", "grok", "kimi", "alibaba", "opencode-go",
    ]

    /// Always reserve a card for these, even when auth/CLI fails remotely.
    static let alwaysShowProviders: Set<String> = [
        "cursor", "codex", "claude", "agy", "zai",
    ]

    /// Cards for providers with usable remaining %, plus always-show primaries.
    func usageCards() -> [AgentUsageCard] {
        var cards: [AgentUsageCard] = []
        var seen = Set<String>()

        for id in Self.headerProviders {
            // "agy-claude" is a synthetic second card sourced from the same
            // quota-axi "agy" entry, showing the Claude/GPT-pool windows.
            if id == "agy-claude" {
                cards.append(contentsOf: syntheticAgyCards())
                continue
            }

            if let provider = provider(matching: id) {
                seen.insert(id)
                let card = Self.card(for: provider)
                if card.isAvailable || Self.alwaysShowProviders.contains(id) {
                    cards.append(card)
                }
            } else if Self.alwaysShowProviders.contains(id) {
                cards.append(
                    AgentUsageCard(
                        provider: id,
                        chips: [],
                        unavailableReason: missingProviderReason()
                    )
                )
            }
        }

        for provider in providers where !seen.contains(Self.canonicalProviderID(provider.provider)) {
            let card = Self.card(for: provider)
            if card.isAvailable {
                cards.append(card)
            }
        }

        return cards
    }

    private func syntheticAgyCards() -> [AgentUsageCard] {
        guard let agyProvider = provider(matching: "agy") else { return [] }
        let windowIds = ["claude_gpt_5h", "claude_gpt_weekly"]
        let picked = windowIds.compactMap { wid in
            agyProvider.windows.first(where: { $0.id == wid })
        }
        if let reason = Self.failedReason(for: agyProvider) {
            guard !picked.isEmpty else { return [] }
            return [AgentUsageCard(provider: "agy-claude", chips: [], unavailableReason: reason)]
        }
        let chips: [AgentUsageChip] = picked.compactMap { window in
            guard let pct = window.percentRemaining else { return nil }
            return AgentUsageChip(
                id: window.id,
                label: Self.chipLabel(for: window, provider: "agy"),
                percentRemaining: Int(pct.rounded()),
                resetsAt: Self.parseResetDate(window.resetsAt),
                windowDuration: Self.windowDuration(for: window)
            )
        }
        guard !chips.isEmpty else { return [] }
        return [AgentUsageCard(provider: "agy-claude", chips: chips, unavailableReason: nil)]
    }

    /// Provider ids quota-axi has used for the same backend across versions.
    private static let providerAliases: [String: String] = [
        "antigravity": "agy",
    ]

    static func canonicalProviderID(_ raw: String) -> String {
        providerAliases[raw.lowercased()] ?? raw.lowercased()
    }

    private func provider(matching id: String) -> QuotaProvider? {
        providers.first { Self.canonicalProviderID($0.provider) == id }
    }

    /// Reason shown when the remote report contains no entry at all for a
    /// provider we always reserve a card for. Naming the CLI version makes the
    /// usual cause (an older `quota-axi` that predates the provider) visible.
    private func missingProviderReason() -> String {
        if let cliVersion, !cliVersion.isEmpty {
            return "\(Self.notReportedReason) \(cliVersion)"
        }
        return Self.notReportedReason
    }

    static let notReportedReason = "Not reported by quota-axi"

    private static func failedReason(for provider: QuotaProvider) -> String? {
        guard provider.state?.status == "error" else { return nil }
        return provider.state?.error ?? "No quota data"
    }

    private static func card(for provider: QuotaProvider) -> AgentUsageCard {
        let id = canonicalProviderID(provider.provider)
        if let reason = failedReason(for: provider) {
            return AgentUsageCard(provider: id, chips: [], unavailableReason: reason)
        }
        if provider.windows.isEmpty {
            let reason = provider.state?.error
                ?? (provider.state?.status == "auth_required" ? "Sign-in required" : "No quota data")
            return AgentUsageCard(provider: id, chips: [], unavailableReason: reason)
        }

        let selected = selectWindows(for: provider)
        let chips = selected.compactMap { window -> AgentUsageChip? in
            guard let percent = window.percentRemaining else { return nil }
            let label = chipLabel(for: window, provider: id)
            return AgentUsageChip(
                id: window.id,
                label: label,
                percentRemaining: Int(percent.rounded()),
                resetsAt: parseResetDate(window.resetsAt),
                windowDuration: Self.windowDuration(for: window)
            )
        }

        if chips.isEmpty {
            return AgentUsageCard(
                provider: id,
                chips: [],
                unavailableReason: provider.state?.error ?? "No quota data"
            )
        }
        return AgentUsageCard(provider: id, chips: chips, unavailableReason: nil)
    }

    /// Compact window set per provider family.
    private static func selectWindows(for provider: QuotaProvider) -> [QuotaWindow] {
        let windows = provider.windows
        switch canonicalProviderID(provider.provider) {
        case "cursor":
            return self.windows(windows, preferring: ["included_usage"])
                ?? firstWindow(windows, kinds: ["monthly"])
                ?? Array(windows.prefix(1))
        case "codex":
            return self.windows(windows, preferring: ["weekly", "seven_day"])
                ?? firstWindow(windows, kinds: ["weekly"])
                ?? []
        case "agy":
            // Show only the primary (Gemini) 5h + weekly windows so the card
            // stays the same height as other single-row provider cards.
            let primaryIds = ["gemini_5h", "gemini_weekly"]
            let picked = primaryIds.compactMap { id in windows.first(where: { $0.id == id }) }
            if !picked.isEmpty { return picked }
            // Fallback: first two windows when primary ids are absent.
            return Array(windows.prefix(2))
        default:
            // Claude / ZAI / others: session + week (skip MCP month — noisy on iOS).
            var picked: [QuotaWindow] = []
            if let fiveHour = window(windows, ids: ["five_hour"]) {
                picked.append(fiveHour)
            }
            if let weekly = window(windows, ids: ["seven_day", "weekly"]) {
                picked.append(weekly)
            }
            // Match kind when ids differ (e.g. provider-specific `*_5h` / `*_weekly`).
            if picked.isEmpty {
                if let session = windows.first(where: { $0.kind == "session" }) {
                    picked.append(session)
                }
                if let weekly = windows.first(where: { $0.kind == "weekly" }) {
                    picked.append(weekly)
                }
            }
            if picked.isEmpty {
                picked = windows.filter { $0.id != "mcp_month" }
            }
            return picked
        }
    }

    private static func windows(_ windows: [QuotaWindow], preferring ids: [String]) -> [QuotaWindow]? {
        let matched = ids.compactMap { id in windows.first(where: { $0.id == id }) }
        return matched.isEmpty ? nil : matched
    }

    private static func window(_ windows: [QuotaWindow], ids: [String]) -> QuotaWindow? {
        for id in ids {
            if let match = windows.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    private static func firstWindow(_ windows: [QuotaWindow], kinds: [String]) -> [QuotaWindow]? {
        guard let match = windows.first(where: { kinds.contains($0.kind ?? "") }) else {
            return nil
        }
        return [match]
    }

    private static func chipLabel(for window: QuotaWindow, provider: String) -> String {
        switch window.id {
        case "five_hour": return "5h"
        case "seven_day", "weekly": return "week"
        case "included_usage": return "all"
        case "mcp_month": return "mcp"
        case "gemini_5h": return "G5h"
        case "gemini_weekly": return "Gwk"
        case "claude_gpt_5h": return "C5h"
        case "claude_gpt_weekly": return "Cwk"
        default:
            if provider == "cursor" { return "all" }
            switch window.kind {
            case "session": return "5h"
            case "weekly": return "week"
            case "monthly": return "mo"
            default:
                let label = window.label ?? window.id
                return label.count <= 6 ? label : String(label.prefix(6))
            }
        }
    }

    private static func parseResetDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Total duration of a quota window so callers can compute the linear burn rate.
    static func windowDuration(for window: QuotaWindow) -> TimeInterval? {
        switch window.id {
        case "five_hour", "gemini_5h", "claude_gpt_5h":
            return 5 * 3600
        case "seven_day", "weekly", "gemini_weekly", "claude_gpt_weekly":
            return 7 * 24 * 3600
        case "included_usage", "mcp_month":
            return 30 * 24 * 3600
        default:
            switch window.kind {
            case "session": return 5 * 3600
            case "weekly":  return 7 * 24 * 3600
            case "monthly": return 30 * 24 * 3600
            default:        return nil
            }
        }
    }
}

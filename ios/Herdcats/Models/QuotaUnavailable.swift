import Foundation

// MARK: - Unavailable quota cards

/// What an unavailable quota card shows. Remote error text is only matched
/// against known cases and never displayed, so identifiers such as
/// `keychain_access_denied` cannot appear as quota data.
enum QuotaUnavailableState: Equatable, Sendable {
    case signInRequired
    case cliOffline
    /// The remote report has no entry for this provider (usually an older CLI).
    case notReported(cliVersion: String?)
    /// Missing or failed quota data.
    case unavailable

    var title: String {
        switch self {
        case .signInRequired: "Sign in"
        case .cliOffline: "CLI offline"
        case .notReported: "Not reported"
        case .unavailable: "Quota unavailable"
        }
    }

    /// Second line naming the CLI that skipped this provider, so a stale remote
    /// `quota-axi` is obvious.
    var detail: String? {
        guard case let .notReported(version?) = self, !version.isEmpty else { return nil }
        return "quota-axi \(version)"
    }

    var canRetry: Bool {
        return true
    }

    var accessibilityDescription: String {
        switch self {
        case .signInRequired: "sign-in required"
        case .cliOffline: "CLI offline"
        case .notReported: detail.map { "not reported by \($0)" } ?? "not reported by quota-axi"
        case .unavailable: "quota unavailable"
        }
    }
}

extension AgentUsageCard {
    /// `nil` while the card has usable quota; a real 0% window is still usable.
    var unavailableState: QuotaUnavailableState? {
        guard !isAvailable else { return nil }
        let reason = (displayUnavailableReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = reason.range(of: QuotaReport.notReportedReason, options: [.anchored, .caseInsensitive]) {
            let version = reason[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return .notReported(cliVersion: version.isEmpty ? nil : version)
        }
        if reason.localizedCaseInsensitiveContains("sign-in")
            || reason.localizedCaseInsensitiveContains("auth") {
            return .signInRequired
        }
        if reason.localizedCaseInsensitiveContains("port discovery") {
            return .cliOffline
        }
        return .unavailable
    }

    /// The `quota-axi --provider` id that refreshes this card. The synthetic
    /// Agy Claude/GPT card comes from the same `agy` entry.
    var quotaProviderID: String {
        provider == "agy-claude" ? "agy" : provider
    }

    /// Card ids a single-provider fetch for `quotaProviderID` refreshes.
    static func cardIDs(forQuotaProvider id: String) -> [String] {
        id == "agy" ? ["agy", "agy-claude"] : [id]
    }

    /// Replaces the cards for one quota provider with a fresh single-provider
    /// report, keeping every other card and the existing order.
    static func merging(
        _ cards: [AgentUsageCard],
        quotaProvider id: String,
        report: QuotaReport
    ) -> [AgentUsageCard] {
        let ids = cardIDs(forQuotaProvider: id)
        var fresh = report.usageCards().filter { ids.contains($0.provider) }
        if !fresh.contains(where: { $0.provider == id }) {
            fresh.insert(AgentUsageCard(provider: id, chips: [], unavailableReason: "No quota data"), at: 0)
        }
        return merging(cards, quotaProvider: id, replacements: fresh)
    }

    private static func merging(
        _ cards: [AgentUsageCard],
        quotaProvider id: String,
        replacements: [AgentUsageCard]
    ) -> [AgentUsageCard] {
        let ids = cardIDs(forQuotaProvider: id)
        guard let insertAt = cards.firstIndex(where: { ids.contains($0.provider) }) else {
            return cards + replacements
        }
        var merged = cards.filter { !ids.contains($0.provider) }
        let offset = cards[..<insertAt].filter { !ids.contains($0.provider) }.count
        merged.insert(contentsOf: replacements, at: offset)
        return merged
    }
}

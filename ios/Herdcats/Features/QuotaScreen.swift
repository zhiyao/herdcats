import SwiftUI

// MARK: - Quota screen

/// Remaining provider quota from remote `quota-axi`, one card per provider.
/// Card order comes from the ⋯ menu; rings use the hybrid quota color scale.
struct QuotaScreen: View {
    @Environment(AppModel.self) private var appModel
    let model: SpacesModel

    @AppStorage(QuotaOrderPreference.storageKey)
    private var quotaOrderRaw = QuotaOrderPreference.default.rawValue

    private var quotaOrderSelection: Binding<QuotaOrderPreference> {
        Binding(
            get: { QuotaOrderPreference(rawValue: quotaOrderRaw) ?? .default },
            set: { quotaOrderRaw = $0.rawValue }
        )
    }

    var body: some View {
        TabSplitView(hint: "Usage for your agents appears on the right.") {
            screen
        }
    }

    private var screen: some View {
        NavigationStack {
            Group {
                if appModel.isOffline && model.usageCards.isEmpty {
                    OfflineHerdView()
                } else {
                    GeometryReader { viewport in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                QuotaCardsView(model: model, showsRecoveryNotice: false)
                                    .frame(minHeight: model.quotaContentState == .loading ? max(260, viewport.size.height - 32) : nil)
                                if let updated = model.usageLastUpdated, !model.usageCards.isEmpty {
                                    QuotaLastUpdatedView(date: updated)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 4)
                            .padding(.bottom, 28)
                            .regularWidthReadable()
                        }
                    }
                }
            }
            .background(Theme.listBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HerdrcatBrandMark(showsHost: true, title: "Quota")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Quota Order", selection: quotaOrderSelection) {
                            ForEach(QuotaOrderPreference.allCases) { preference in
                                Label(preference.title, systemImage: preference.systemImage)
                                    .tag(preference)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.jost(16, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Quota Options")
                    .accessibilityIdentifier("quota-options-menu")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .bottomNotice {
                if !appModel.isOffline {
                    QuotaRecoveryNotice(model: model)
                }
            }
            .task { await model.refreshUsage(appModel.connection) }
            .refreshable { await model.refreshUsage(appModel.connection, force: true) }
        }
    }
}

/// Shared by the tab and standalone quota card hosts (including UI fixtures).
struct QuotaRecoveryNotice: View {
    @Environment(AppModel.self) private var appModel
    let model: SpacesModel
    var body: some View {
        switch model.quotaContentState {
        case .error(let message):
            ErrorBanner(message: message, retry: {
                Task { await model.refreshUsage(appModel.connection, force: true) }
            })
            .padding(.vertical, 4)
            .accessibilityIdentifier("quota-load-error")
        case .notSetup:
            QuotaAxiNotSetupView(model: model).padding(.vertical, 4)
        case .empty:
            RecoveryNotice(title: "No quota data available", systemImage: "gauge.with.dots.needle.67percent", identifier: "quota-load-empty") {
                Text("Check quota again to load the latest usage from this computer.")
            } actions: {
                Button("Retry") { Task { await model.refreshUsage(appModel.connection, force: true) } }
            }
            .padding(.vertical, 4)
        case .cards, .loading: EmptyView()
        }
    }
}

// MARK: - Quota last updated

/// Periodic relative "Updated …" indicator. Ticks every 30 seconds rather than
/// every second to keep the background UI calm between 60s quota refreshes.
struct QuotaLastUpdatedView: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: date, by: 30)) { context in
            Text(QuotaUpdatedFormat.label(for: date, now: context.date))
                .font(.jost(12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
        .id(date)
        .accessibilityIdentifier("quota-last-updated")
    }
}

/// Compact relative format for quota refresh timestamps ("Updated just now",
/// "Updated 30s ago", "Updated 2m ago", "Updated 1h ago", "Updated 1d ago").
enum QuotaUpdatedFormat {
    static func label(for date: Date, now: Date = .now) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 30 {
            return "Updated just now"
        }
        if elapsed < 60 {
            return "Updated 30s ago"
        }
        let minutes = Int(elapsed / 60)
        if minutes < 60 {
            return "Updated \(minutes)m ago"
        }
        let hours = Int(elapsed / 3600)
        if hours < 24 {
            return "Updated \(hours)h ago"
        }
        let days = Int(elapsed / 86400)
        return "Updated \(days)d ago"
    }
}

// MARK: - Quota cards

/// Remaining quota for Cursor / Codex / Claude / Agy from remote `quota-axi`.
struct QuotaCardsView: View {
    @Environment(AppModel.self) private var appModel
    let model: SpacesModel
    var showsRecoveryNotice = true
    @State private var showsAgySignIn = false
    @AppStorage(QuotaOrderPreference.storageKey)
    private var quotaOrderRaw = QuotaOrderPreference.default.rawValue

    private var quotaOrder: QuotaOrderPreference {
        QuotaOrderPreference(rawValue: quotaOrderRaw) ?? .default
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch model.quotaContentState {
            case .cards:
                cardsRow
            case .notSetup:
                EmptyView()
            case .loading:
                usageStatusCard
            case .error, .empty:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.usageCards.isEmpty)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.quotaAxiMissing)
        .frame(maxWidth: .infinity, maxHeight: showsRecoveryNotice ? .infinity : nil, alignment: .topLeading)
        .bottomNotice {
            if showsRecoveryNotice { QuotaRecoveryNotice(model: model) }
        }
    }

    private var usageStatusCard: some View {
        LazyCatLoadingView(message: "Loading quota…")
            .frame(minHeight: 260)
            .accessibilityIdentifier("quota-content-loading")
    }

    private var cardsRow: some View {
        // Tick each minute so the order, countdowns, and pace colors stay
        // current between quota refreshes.
        TimelineView(.everyMinute) { context in
            let cards = quotaOrder.ordered(model.usageCards, now: context.date)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(cards) { card in
                    Group {
                        if card.provider == "agy" {
                            Button { showsAgySignIn = true } label: {
                                AgentUsageCardView(card: card, now: context.date)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens Agy sign-in on the remote machine")
                            .accessibilityIdentifier("agy-usage-card")
                        } else {
                            AgentUsageCardView(card: card, now: context.date)
                        }
                    }
                    // Outside the Agy button so the two taps stay separate.
                    .overlay(alignment: .topTrailing) { retryButton(for: card) }
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: cards.map(\.id))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quota Remaining")
        .sheet(isPresented: $showsAgySignIn) {
            AgySignInSheet(model: model)
        }
    }

    /// Re-reads only this card's provider; shown while its quota is unavailable.
    @ViewBuilder
    private func retryButton(for card: AgentUsageCard) -> some View {
        if card.unavailableState?.canRetry == true {
            let provider = card.quotaProviderID
            let isRetrying = model.retryingUsageProviders.contains(provider)
            Button {
                Task { await model.retryUsage(provider: provider, connection: appModel.connection) }
            } label: {
                Group {
                    if isRetrying {
                        CircularArcSpinner(size: 11)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.jost(11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isRetrying)
            .accessibilityLabel("Retry \(card.displayTitle) Quota")
            .accessibilityIdentifier("quota-retry-\(card.provider)")
        }
    }
}

// MARK: - Quota axi not setup view

/// Card shown in QuotaScreen when `quota-axi` is not installed on the remote machine,
/// providing the install command, copy action, documentation link, and refresh trigger.
struct QuotaAxiNotSetupView: View {
    @Environment(AppModel.self) private var appModel
    let model: SpacesModel
    @State private var didCopyCommand = false

    static let setupGuideURL = URL(string: "https://github.com/kunchenguid/quota-axi#quick-start")!
    static let installCommand = "npm i -g quota-axi"

    var body: some View {
        RecoveryNotice(title: "quota-axi is not installed", systemImage: "gauge.with.dots.needle.67percent", identifier: "quota-setup-notice") {
            Text("Install quota-axi on the remote machine to view remaining quota and reset countdowns for Claude, Cursor, Codex, Agy, and other providers.")
            Text(Self.installCommand)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
        } actions: {
            Button(didCopyCommand ? "Copied" : "Copy command") {
                UIPasteboard.general.string = Self.installCommand
                didCopyCommand = true
                Task { try? await Task.sleep(for: .seconds(2)); didCopyCommand = false }
            }
            .accessibilityLabel(didCopyCommand ? "Copied install command" : "Copy install command")
            .accessibilityIdentifier("quota-axi-copy-command-button")
            Link("Setup guide", destination: Self.setupGuideURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("quota-axi-setup-guide-link")
            Button {
                Task { await model.refreshUsage(appModel.connection, force: true) }
            } label: {
                HStack {
                    if model.isRefreshingUsage { CircularArcSpinner(size: 12) }
                    Text("Check again")
                }
            }
            .disabled(model.isRefreshingUsage)
            .accessibilityIdentifier("quota-axi-check-button")
        }
    }
}

private struct AgentUsageCardView: View {
    let card: AgentUsageCard
    let now: Date

    private var tint: Color { AgentKindVisual.color(for: card.provider) }

    private var title: String { card.displayTitle }

    private var chips: [AgentUsageChip] { Array(card.ringOrderedChips.prefix(2)) }

    /// Fixed body height so one- and two-ring cards (and unavailable cards)
    /// line up; fits two stacked percent + countdown legends.
    private static let bodyHeight: CGFloat = 66

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                AgentKindIcon(kind: card.provider, size: 11)
                Text(title)
                    .font(.jost(11, weight: .bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }

            if card.isAvailable {
                HStack(spacing: 10) {
                    QuotaRings(chips: chips, now: now)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                            chipLegend(chip, inner: index > 0)
                        }
                    }
                }
                .frame(height: Self.bodyHeight, alignment: .leading)
            } else {
                let state = card.unavailableState ?? .unavailable
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.jost(12, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                    if let detail = state.detail {
                        Text(detail)
                            .font(.jost(9, weight: .semibold))
                            .foregroundStyle(.quaternary)
                            .lineLimit(1)
                    }
                }
                .frame(height: Self.bodyHeight, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .herdrCard(cornerRadius: DesignSystem.CornerRadius.lg, showsBorder: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilityLabel(now: now))
    }

    /// Percent plus time until reset. The countdown turns the warning color
    /// when this window will run out before it resets.
    private func chipLegend(_ chip: AgentUsageChip, inner: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(chip.percentText)
                .font(.jost(16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.quotaColor(for: chip, now: now, inner: inner))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(chip.displayLabel(now: now))
                .font(.jost(9, weight: .semibold))
                .foregroundStyle(Theme.quotaCountdownStyle(for: chip, now: now, inner: inner))
                .textCase(.uppercase)
                .lineLimit(1)
        }
    }
}

/// Nested quota rings. The longest window is the outer ring.
private struct QuotaRings: View {
    let chips: [AgentUsageChip]
    let now: Date

    private let size: CGFloat = 58
    private let lineWidth: CGFloat = 8
    private let gap: CGFloat = 3

    var body: some View {
        ZStack {
            ForEach(Array(chips.enumerated()), id: \.element.id) { index, chip in
                QuotaRing(
                    chip: chip,
                    now: now,
                    inner: index > 0,
                    diameter: size - CGFloat(index) * (lineWidth * 2 + gap),
                    lineWidth: lineWidth
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One hybrid-colored ring with a tick at the even-burn reference point.
private struct QuotaRing: View {
    let chip: AgentUsageChip
    let now: Date
    /// Inner rings share the same semantic color as the outer ring.
    let inner: Bool
    let diameter: CGFloat
    let lineWidth: CGFloat

    var body: some View {
        let color = Theme.quotaColor(for: chip, now: now, inner: inner)
        let progress = min(1, max(0, Double(chip.percentRemaining) / 100))
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let expected = chip.expectedPercentRemaining(now: now) {
                Capsule()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 2, height: lineWidth - 2)
                    .offset(y: -(diameter - lineWidth) / 2)
                    .rotationEffect(.degrees(expected / 100 * 360))
            }
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: chip.percentRemaining)
    }
}

extension AgentUsageCard {
    /// VoiceOver summary; unavailable cards never read out the remote error.
    func accessibilityLabel(now: Date) -> String {
        guard let state = unavailableState else {
            let parts = Array(ringOrderedChips.prefix(2)).map { chip in
                let pace = chip.isBehindPace(now: now) ? ", runs out before reset" : ""
                return "\(chip.percentRemaining) percent left, \(chip.displayLabel(now: now))\(pace)"
            }
            return "\(displayTitle): \(parts.joined(separator: "; "))"
        }
        return "\(displayTitle): \(state.accessibilityDescription)"
    }
}

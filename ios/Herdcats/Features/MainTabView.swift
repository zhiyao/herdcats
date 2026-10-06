import Observation
import SwiftUI

// MARK: - Main tab view

/// Keeps the chosen tab while replacing navigation and data on machine changes.
struct MainTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedTab = ConnectedTabsView.MainTab.requestedInitialTab()

    var body: some View {
        ConnectedTabsView(selectedTab: $selectedTab)
            .environment(appModel.selectedMachineModel ?? appModel)
            .id(appModel.isShowingAllMachines ? "all" : appModel.selectedMachineModel?.connectionIdentity?.storageKey ?? "gateway")
            // The session view appears while still connecting; rediscover
            // once connected (and after reconnects, which reset machines).
            .task(id: appModel.phase) {
                guard case .connected = appModel.phase else { return }
                await appModel.discoverMachines()
            }
    }
}

/// Owns the selected machine's shared data and lifecycle-aware refresh loop.
struct ConnectedTabsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = SpacesModel()
    @Binding var selectedTab: MainTab

    enum MainTab: String, Hashable {
        case spaces
        case agents
        case quota
        case settings

        /// Optional launch-argument driven initial tab (UI tests, screenshots):
        /// `-hc.tab agents` / `-hc.tab spaces` / `-hc.tab quota` / `-hc.tab settings`.
        static func requestedInitialTab() -> MainTab {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-hc.tab"),
                  index + 1 < arguments.count,
                  let tab = MainTab(rawValue: arguments[index + 1]) else {
                if AutoConnect.configIfRequested() != nil || LaunchPreference.autoConnectConfig() != nil {
                    return .agents
                }
                return .spaces
            }
            return tab
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SpacesScreen(model: model)
                .tabItem {
                    Label("Spaces", systemImage: "square.grid.3x3")
                }
                .tag(MainTab.spaces)

            AgentsScreen(model: model)
                .tabItem {
                    Label("Agents", systemImage: "cpu")
                }
                .badge(model.blockedAgentCount)
                .tag(MainTab.agents)

            QuotaScreen(model: model)
                .tabItem {
                    Label("Quota", systemImage: "gauge.with.dots.needle.67percent")
                }
                .tag(MainTab.quota)

            SettingsScreen(model: model)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(MainTab.settings)
        }
        .environment(model)
        .task(id: appModel.machineCatalog.machines) {
            model.stopAutoRefresh()
            if appModel.isShowingAllMachines {
                await model.bindMachines(appModel)
            } else {
                model.bindConnectionScope(appModel.connectionIdentity)
            }
            guard !Task.isCancelled else { return }
            let active = scenePhase == .active
            model.isSceneActive = active
            appModel.isSceneActive = active
            for source in model.machineSources { source.app.isSceneActive = active }
            await model.refresh(appModel.connection)
            guard !Task.isCancelled else { return }
            model.startAutoRefresh(appModel.connection)
        }
        .onChange(of: appModel.phase) { oldPhase, newPhase in
            if case .connected = newPhase, case .offline = oldPhase {
                Task {
                    await model.refresh(appModel.connection)
                    await model.refreshUsage(appModel.connection, force: true)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            let active = phase == .active
            model.isSceneActive = active
            appModel.isSceneActive = active
            for source in model.machineSources { source.app.isSceneActive = active }
            if active {
                if appModel.isOffline {
                    Task { await appModel.reconnect(automatically: true) }
                } else if model.autoRefreshEnabled {
                    Task {
                        await model.refresh(appModel.connection)
                        await model.refreshUsage(appModel.connection, force: true)
                    }
                }
            }
        }
        .onChange(of: model.autoRefreshEnabled) { _, enabled in
            for source in model.machineSources { source.model.autoRefreshEnabled = enabled }
        }
        .onDisappear {
            model.stopAutoRefresh()
        }
    }
}

// MARK: - Agents screen

/// Every agent across every space. Ordered by herdr's attention priority
/// (flat queue) or grouped by space — both selectable from the ⋯ menu.
/// Tapping a row opens that agent's pane directly.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: SpacesModel
    @State private var raisedCardID: String?

    @AppStorage(AgentsSortPreference.storageKey)
    private var sortRaw = AgentsSortPreference.default.rawValue

    private var sort: AgentsSortPreference {
        AgentsSortPreference(rawValue: sortRaw) ?? .default
    }

    private var sortSelection: Binding<AgentsSortPreference> {
        Binding(
            get: { AgentsSortPreference(rawValue: sortRaw) ?? .default },
            set: { sortRaw = $0.rawValue }
        )
    }

    /// The flat attention queue — herdr's `priority` agent panel sort:
    /// blocked, done, working, idle, unknown, latest state change first.
    private var items: [AgentListItem] {
        model.spaces
            .flatMap { space in space.agents.map { AgentListItem(space: space, agent: $0) } }
            .sorted(by: AgentListItem.attentionOrder)
    }

    /// Spaces with their agents — herdr's `spaces` agent panel sort.
    private var sections: [(space: Space, items: [AgentListItem])] {
        AgentListItem.grouped(in: model.spaces)
    }

    private var cardOrder: [ReorderingCard] {
        let displayedItems = sort == .priority ? items : sections.flatMap { $0.items }
        return displayedItems.map { item in
            ReorderingCard(
                id: item.id,
                priorityKey: "\(item.agent.agentStatus)|\(item.agent.stateChangeSeq.map { String($0) } ?? "")"
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if appModel.isOffline && items.isEmpty {
                    OfflineHerdView()
                } else if items.isEmpty && (model.isLoading || !model.hasLoadedAgentList) {
                    loadingSkeleton
                } else if items.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            switch sort {
                            case .priority:
                                let currentItems = items
                                ForEach(currentItems) { item in
                                    agentRow(item, showsSpace: true)
                                }
                            case .spaces:
                                let currentSections = sections
                                ForEach(Array(currentSections.enumerated()), id: \.element.space.id) { index, section in
                                    if model.showsAllMachines,
                                       index == 0 || currentSections[index - 1].space.machine?.id != section.space.machine?.id {
                                        MachineSectionHeader(name: section.space.machine?.label ?? "Machine")
                                    }
                                    spaceHeader(section.space)
                                    ForEach(section.items) { item in
                                        agentRow(item, showsSpace: false)
                                    }
                                }
                            }
                        }
                        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.12), value: cardOrder.map(\.id))
                        .onChange(of: cardOrder) { old, new in
                            raisedCardID = ReorderingCard.movingID(from: old, to: new)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                    }
                }
            }
            .background(Theme.listBackground.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HerdrcatBrandMark(showsHost: true, title: "Agents")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: sortSelection) {
                            ForEach(AgentsSortPreference.allCases) { preference in
                                Label(preference.title, systemImage: preference.systemImage)
                                    .tag(preference)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Agent List Options")
                    .accessibilityIdentifier("agent-list-options-menu")
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: AgentListItem.self) { item in
                if let target = model.app(for: item.space, fallback: appModel) {
                    WorkspacePaneView(space: item.space, initialPaneID: item.agent.paneId)
                        .environment(target)
                        .environment(model.model(for: item.space))
                } else {
                    ContentUnavailableView("Machine Unavailable", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                }
            }
            .overlay(alignment: .bottom) {
                if let error = model.errorMessage,
                   model.hasLoadedAgentList,
                   case .connected = appModel.phase,
                   !HerdrConnection.isDisconnectionOrTransitionMessage(error) {
                    VStack {
                        Spacer()
                        ErrorBanner(message: error) {
                            Task { await model.refresh(appModel.connection) }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: model.errorMessage == nil)
            .refreshable {
                await model.refresh(appModel.connection)
            }
            .connectionStatusBanner(appModel: appModel)
        }
    }

    // MARK: Pieces

    private var loadingSkeleton: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(0..<4) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 6) {
                                skeletonBar(width: 100, height: 12)
                                skeletonBar(width: index.isMultiple(of: 2) ? 170 : 140, height: 18)
                            }
                            Spacer(minLength: 4)
                            skeletonBar(width: 58, height: 22)
                        }
                        HStack(spacing: 8) {
                            skeletonBar(width: 64, height: 22)
                            skeletonBar(width: 90, height: 22)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .herdrCard()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading agents")
        .accessibilityIdentifier("agent-list-loading")
    }

    private func skeletonBar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Theme.subtleFill)
            .frame(width: width, height: height)
    }

    private func agentRow(_ item: AgentListItem, showsSpace: Bool) -> some View {
        NavigationLink(value: item) {
            AgentListRow(
                item: item,
                lastUpdated: model.model(for: item.space).lastUpdatedByPaneID[item.agent.paneId],
                showsSpace: showsSpace,
                machineLabel: model.showsAllMachines && sort == .priority ? item.space.machine?.label : nil
            )
        }
        .buttonStyle(.plain)
        .zIndex(raisedCardID == item.id ? 1 : 0)
        .transition(.opacity)
    }

    private func spaceHeader(_ space: Space) -> some View {
        HStack(spacing: 8) {
            Text("#\(space.workspace.number) · \(space.label)")
                .font(.appLabelSm.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            StatusPill(status: space.status)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Space \(space.label), \(space.status.label)")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No agents running")
                .font(.title3.weight(.semibold))
            Text("Launch an agent inside a herdr space —\nit will show up here on the next refresh.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - Agent list item

struct AgentListItem: Identifiable, Hashable {
    let space: Space
    let agent: AgentEntry

    var id: String {
        guard let machine = space.machine else { return agent.paneId }
        return machine.id + "|p=" + ConnectionIdentity.encodeComponent(agent.paneId)
    }

    var status: AgentStatus {
        AgentStatus(rawValue: agent.agentStatus) ?? .unknown
    }

    var title: String {
        agent.displayTitle
    }

    /// Herdr's attention queue: `AgentStatus.attentionPriority` descending,
    /// then the most recent state change first — the same order herdr's
    /// priority-sorted agent panel uses.
    static func attentionOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.status.attentionPriority != rhs.status.attentionPriority {
            return lhs.status.attentionPriority > rhs.status.attentionPriority
        }
        // Sequence numbers belong to one server; never compare them across machines.
        if lhs.space.machine?.id != rhs.space.machine?.id {
            return (lhs.space.machine?.order ?? 0, lhs.space.machine?.id ?? "")
                < (rhs.space.machine?.order ?? 0, rhs.space.machine?.id ?? "")
        }
        // Older servers may omit the sequence; keep those agents after known changes.
        switch (lhs.agent.stateChangeSeq, rhs.agent.stateChangeSeq) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        return (lhs.space.workspace.number, lhs.title, lhs.id)
            < (rhs.space.workspace.number, rhs.title, rhs.id)
    }

    /// One section per space that actually hosts agents — spaces in workspace
    /// order, agents in the space's join order — mirroring herdr's `spaces`
    /// agent panel sort. Agent-less spaces are hidden instead of rendering an
    /// empty header.
    static func grouped(in spaces: [Space]) -> [(space: Space, items: [AgentListItem])] {
        spaces.compactMap { space in
            guard !space.agents.isEmpty else { return nil }
            return (space, space.agents.map { AgentListItem(space: space, agent: $0) })
        }
    }
}

// MARK: - Agent list row

struct AgentListRow: View {
    let item: AgentListItem
    var lastUpdated: Date?
    /// Grouped-by-space sections already name the space in their header.
    var showsSpace = true
    var machineLabel: String? = nil

    private var agent: AgentEntry { item.agent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if showsSpace {
                        Text("#\(item.space.workspace.number) · \(item.space.label)")
                            .font(.appLabelSm.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(item.title)
                        .font(.appHeadlineSm)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if agent.focused {
                    Image(systemName: "scope")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                }
                StatusPill(status: item.status)
            }

            HStack(spacing: 8) {
                AgentBadge(kind: agent.agent)
                if let machineLabel {
                    Label(machineLabel, systemImage: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if machineLabel == nil, !agent.shortCwd.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 9, weight: .semibold))
                        Text(agent.shortCwd)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Theme.subtleFill))
                }

                Spacer(minLength: 0)

                if let lastUpdated {
                    Text(PaneUpdatedFormat.label(for: lastUpdated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .herdrCard()
    }
}

// MARK: - Shared toolbar

struct HerdrcatBrandMark: View {
    @Environment(AppModel.self) private var appModel
    var showsHost = false
    var title: String? = nil

    private var host: String? {
        guard showsHost else { return nil }
        switch appModel.phase {
        case let .connected(host, _):
            return appModel.isShowingAllMachines ? "All Machines" : host
        case let .offline(host, _):
            return appModel.isShowingAllMachines ? "All Machines" : host
        default:
            return nil
        }
    }

    private var shortHost: String {
        if appModel.isShowingAllMachines { return "All Machines" }
        if let machine = appModel.selectedMachine { return machine.label }
        let fullHost = host ?? ""
        // Only abbreviate DNS names; keep numeric and IPv6 addresses intact.
        if fullHost.contains(":") || fullHost.allSatisfy({ $0.isNumber || $0 == "." }) {
            return fullHost
        }
        return String(fullHost.split(separator: ".").first ?? Substring(fullHost))
    }

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 8) {
                if title == nil {
                    Image("HerdrcatLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle.continuous(DesignSystem.CornerRadius.xs))
                }
                Text(title ?? "Herdcats")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            if let host {
                Menu {
                    Text(host)
                    Divider()
                    Button {
                        appModel.machineCatalog.selectAllMachines()
                    } label: {
                        Label("All Machines", systemImage: appModel.machineCatalog.isShowingAllMachines ? "checkmark" : "desktopcomputer")
                    }
                    Divider()
                    Button {
                        Task { await appModel.machineCatalog.selectMachine(nil) }
                    } label: {
                        Label(appModel.machineCatalog.machineDisplayName,
                              systemImage: !appModel.machineCatalog.isShowingAllMachines && appModel.selectedMachine == nil ? "checkmark" : "desktopcomputer")
                    }
                    ForEach(appModel.machineCatalog.machines) { machine in
                        Button {
                            Task { await appModel.machineCatalog.selectMachine(machine) }
                        } label: {
                            Label(machine.label + (machine.enabled ? "" : " (disabled)"),
                                  systemImage: appModel.selectedMachine?.id == machine.id ? "checkmark" : "desktopcomputer")
                        }
                        .disabled(!machine.enabled)
                    }
                    Divider()
                    Button("Refresh Machines", systemImage: "arrow.clockwise") {
                        Task { await appModel.machineCatalog.discoverMachines() }
                    }
                    .disabled(appModel.machineCatalog.isDiscoveringMachines)
                    if let error = appModel.machineCatalog.machineDiscoveryError {
                        Text(error)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(shortHost).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption2)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                }
                .accessibilityLabel("Machine: \(host)")
                .accessibilityIdentifier("machine-picker")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

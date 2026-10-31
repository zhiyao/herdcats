import SwiftUI

// MARK: - Sidebar tabs

/// What the sidebar's tab switcher needs from `ConnectedTabsView`: the
/// selected tab and the blocked-agent count for the Agents badge.
struct SidebarTabs {
    var selection: Binding<ConnectedTabsView.MainTab>
    var blockedCount: Int
}

private struct SidebarTabsKey: EnvironmentKey {
    static let defaultValue: SidebarTabs? = nil
}

extension EnvironmentValues {
    var sidebarTabs: SidebarTabs? {
        get { self[SidebarTabsKey.self] }
        set { self[SidebarTabsKey.self] = newValue }
    }
}

extension ConnectedTabsView.MainTab {
    var title: LocalizedStringKey {
        switch self {
        case .spaces: "Spaces"
        case .agents: "Agents"
        case .quota: "Quota"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .spaces: "square.grid.3x3"
        case .agents: "cpu"
        case .quota: "gauge.with.dots.needle.67percent"
        case .settings: "gearshape"
        }
    }

    static let displayOrder: [ConnectedTabsView.MainTab] = [.spaces, .agents, .quota, .settings]
}

/// Column visibility is shared by every tab, so collapsing the sidebar in one
/// tab keeps it collapsed after switching to another.
enum SidebarVisibility {
    static let storageKey = "sidebar.columnVisibility"
}

// MARK: - Switcher

/// The tab switcher on regular width. It sits at the top of the sidebar in
/// place of the system tab bar, which floats over the detail column on iPad.
struct SidebarTabSwitcher: View {
    @Environment(\.sidebarTabs) private var tabs

    var body: some View {
        if let tabs {
            HStack(spacing: 2) {
                ForEach(ConnectedTabsView.MainTab.displayOrder, id: \.self) { tab in
                    item(tab, tabs: tabs)
                }
            }
            .padding(4)
            .background(Theme.subtleFill, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar-tab-switcher")
        }
    }

    private func item(_ tab: ConnectedTabsView.MainTab, tabs: SidebarTabs) -> some View {
        let isSelected = tabs.selection.wrappedValue == tab
        return Button {
            tabs.selection.wrappedValue = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.jost(15, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        if tab == .agents, tabs.blockedCount > 0 {
                            Text("\(tabs.blockedCount)")
                                .font(.jost(9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(Color.red, in: Capsule())
                                .offset(x: 9, y: -6)
                        }
                    }
                Text(tab.title)
                    .font(.jost(10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(Theme.sky.opacity(0.45))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("sidebar-tab-\(tab.rawValue)")
    }
}

// MARK: - Tabs without a list

/// Quota and Settings on regular width: the sidebar is only the tab switcher,
/// and the screen fills the detail column. Compact width shows the screen
/// as it always did.
struct TabSplitView<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage(SidebarVisibility.storageKey)
    private var visibilityRaw = NavigationSplitViewVisibility.all.storageValue
    let hint: LocalizedStringKey
    let content: Content

    init(hint: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.hint = hint
        self.content = content()
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { NavigationSplitViewVisibility(storageValue: visibilityRaw) },
            set: { visibilityRaw = $0.storageValue }
        )
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView(columnVisibility: columnVisibility) {
                Text(hint)
                    .font(.jost(.footnote))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.listBackground.ignoresSafeArea())
                    .safeAreaInset(edge: .top, spacing: 0) { SidebarTabSwitcher() }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
            } detail: {
                content
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            content
        }
    }
}

extension View {
    /// The sidebar's tab switcher replaces the system tab bar on regular width.
    func hidesSystemTabBarWhenRegular(_ sizeClass: UserInterfaceSizeClass?) -> some View {
        background(SystemTabBarHider(isHidden: sizeClass == .regular))
    }
}

/// Hides the enclosing `UITabBarController`'s bar. SwiftUI's
/// `.toolbar(.hidden, for: .tabBar)` hides the iPad floating bar but leaves
/// its top inset on the tab shown at launch; UIKit updates the inset itself.
private struct SystemTabBarHider: UIViewControllerRepresentable {
    let isHidden: Bool

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.isBarHidden = isHidden
        probe.apply()
    }

    final class Probe: UIViewController {
        var isBarHidden = false

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            guard #available(iOS 18.0, *), let controller = tabBarController,
                  controller.isTabBarHidden != isBarHidden else { return }
            controller.setTabBarHidden(isBarHidden, animated: false)
        }
    }
}

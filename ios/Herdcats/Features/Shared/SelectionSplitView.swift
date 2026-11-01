import SwiftUI

// MARK: - Pane chrome environment

private struct ShowsPaneSwitcherKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ShowsPaneBackButtonKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether a pane shows its sibling-pane switcher strip. The split view
    /// turns it off while the list column is visible, because the list
    /// already switches panes.
    var showsPaneSwitcher: Bool {
        get { self[ShowsPaneSwitcherKey.self] }
        set { self[ShowsPaneSwitcherKey.self] = newValue }
    }

    /// Whether a pane draws its own Back control. Off in the split view's
    /// detail column, where the split view owns navigation.
    var showsPaneBackButton: Bool {
        get { self[ShowsPaneBackButtonKey.self] }
        set { self[ShowsPaneBackButtonKey.self] = newValue }
    }
}

// MARK: - Selection split view

/// A list that opens its items in a second column on regular width and
/// pushes them on a stack on compact width. Both layouts read one
/// `selection`, a stable id, so folding or unfolding keeps the user's place:
/// the stack's path is derived from it, and the split view selects it.
///
/// Callers draw rows that set `selection` directly when `horizontalSizeClass`
/// is regular and use `NavigationLink(value: id)` when compact.
struct SelectionSplitView<Sidebar: View, Detail: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage(SidebarVisibility.storageKey)
    private var visibilityRaw = NavigationSplitViewVisibility.all.storageValue
    @Binding var selection: String?
    let emptyTitle: LocalizedStringKey
    let emptySystemImage: String
    let sidebar: Sidebar
    let detail: (String) -> Detail

    init(
        selection: Binding<String?>,
        emptyTitle: LocalizedStringKey,
        emptySystemImage: String,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: @escaping (String) -> Detail
    ) {
        _selection = selection
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.sidebar = sidebar()
        self.detail = detail
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { NavigationSplitViewVisibility(storageValue: visibilityRaw) },
            set: { visibilityRaw = $0.storageValue }
        )
    }

    /// The stack's path is just the selected id, so Back clears the selection.
    private var stackPath: Binding<[String]> {
        Binding(
            get: { selection.map { [$0] } ?? [] },
            set: { selection = $0.last }
        )
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView(columnVisibility: columnVisibility) {
                sidebar
                    .safeAreaInset(edge: .bottom, spacing: 0) { SidebarTabSwitcher() }
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
            } detail: {
                Group {
                    if let selection {
                        detail(selection)
                            // A new item gets fresh pane state, not the last item's.
                            .id(selection)
                    } else {
                        ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
                            .background(Theme.backgroundGradient.ignoresSafeArea())
                    }
                }
                .environment(\.showsPaneSwitcher, columnVisibility.wrappedValue == .detailOnly)
                .environment(\.showsPaneBackButton, false)
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: stackPath) {
                sidebar
                    .navigationDestination(for: String.self) { id in
                        detail(id)
                    }
            }
        }
    }
}

extension NavigationSplitViewVisibility {
    /// `NavigationSplitViewVisibility` isn't `RawRepresentable`, so scene
    /// storage keeps it as a string.
    var storageValue: String {
        switch self {
        case .detailOnly: "detailOnly"
        case .doubleColumn: "doubleColumn"
        case .automatic: "automatic"
        default: "all"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "detailOnly": self = .detailOnly
        case "doubleColumn": self = .doubleColumn
        case "automatic": self = .automatic
        default: self = .all
        }
    }
}

// MARK: - Readable width

extension View {
    /// Centres content in a readable column on regular width so Quota and
    /// Settings don't stretch across a whole iPad. Compact width is unchanged.
    func regularWidthReadable(maxWidth: CGFloat = 680) -> some View {
        modifier(RegularWidthReadable(maxWidth: maxWidth))
    }
}

private struct RegularWidthReadable: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

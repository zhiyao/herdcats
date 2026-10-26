import SwiftUI

// MARK: - Add pane kind and request

enum AddPaneKind: String, CaseIterable {
    case pane
    case tab
}

struct AddPaneRequest {
    var kind: AddPaneKind
    var name: String
}

// MARK: - Workspace actions

/// A workspace-level action awaiting confirmation in a drawer.
enum WorkspaceAction: Identifiable {
    case rename(Workspace)
    case close(Workspace)
    case deleteWorktree(Workspace)

    var id: String {
        switch self {
        case .rename: "rename"
        case .close: "close"
        case .deleteWorktree: "deleteWorktree"
        }
    }

    var workspace: Workspace {
        switch self {
        case let .rename(workspace), let .close(workspace), let .deleteWorktree(workspace):
            workspace
        }
    }
}

/// Values collected by the confirmation drawer for a workspace action.
enum WorkspaceActionOutcome {
    case rename(String)
    case close
    case deleteWorktree(force: Bool, trustRepository: Bool)
}

/// Bottom drawer that confirms workspace-level actions (rename, close,
/// delete worktree checkout) before they run on the remote machine.
struct WorkspaceActionDrawer: View {
    let action: WorkspaceAction
    let onConfirm: (WorkspaceActionOutcome) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var force = false
    @State private var trustRepository = false

    init(
        action: WorkspaceAction,
        onConfirm: @escaping (WorkspaceActionOutcome) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.action = action
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _name = State(initialValue: action.workspace.label)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func estimatedHeight(for action: WorkspaceAction) -> CGFloat {
        switch action {
        case .rename: 320
        case .close: 300
        case .deleteWorktree: 470
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch action {
            case .rename:
                Text("Rename Workspace")
                    .font(.jost(.title3, weight: .semibold))
                Text("Enter a new label for this workspace. Pane names are unchanged.")
                    .font(.jost(.subheadline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Workspace name")
                        .font(.jost(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Workspace Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Theme.fieldBackground,
                            in: RoundedRectangle.continuous(DesignSystem.CornerRadius.md)
                        )
                        .accessibilityIdentifier("workspace-rename-text-field")
                }
                Spacer(minLength: 8)
                VStack(spacing: 10) {
                    Button("Rename Workspace") {
                        onConfirm(.rename(name))
                    }
                    .buttonStyle(.herdrPrimary())
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("workspace-rename-confirm-button")

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.herdrGhost())
                }

            case .close:
                Text("Close Workspace")
                    .font(.jost(.title3, weight: .semibold))
                Text(
                    "This closes “\(action.workspace.label)” and stops all of its tabs and panes on the remote machine."
                )
                .font(.jost(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                VStack(spacing: 10) {
                    Button("Close Workspace", role: .destructive) {
                        onConfirm(.close)
                    }
                    .buttonStyle(.herdrPrimary(tint: Theme.destructive))
                    .accessibilityIdentifier("workspace-close-confirm-button")

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.herdrGhost())
                }

            case .deleteWorktree:
                Text("Delete Worktree Checkout")
                    .font(.jost(.title3, weight: .semibold))
                VStack(alignment: .leading, spacing: 8) {
                    Text("Checkout")
                        .font(.jost(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(action.workspace.worktree?.checkoutPath ?? "")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Theme.fieldBackground,
                            in: RoundedRectangle.continuous(DesignSystem.CornerRadius.md)
                        )
                }
                Text(
                    "This deletes the checkout folder on the remote machine and closes this workspace. The worktree branch itself is not deleted."
                )
                .font(.jost(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: $force) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Force delete")
                            .font(.jost(.subheadline, weight: .medium))
                        Text("Remove even when the checkout has uncommitted changes.")
                            .font(.jost(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("workspace-delete-force-toggle")
                Toggle(isOn: $trustRepository) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trust repository")
                            .font(.jost(.subheadline, weight: .medium))
                        Text("Required when this checkout is the repository’s main checkout.")
                            .font(.jost(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityIdentifier("workspace-delete-trust-toggle")
                Spacer(minLength: 8)
                VStack(spacing: 10) {
                    Button("Delete Checkout", role: .destructive) {
                        onConfirm(.deleteWorktree(force: force, trustRepository: trustRepository))
                    }
                    .buttonStyle(.herdrPrimary(tint: Theme.destructive))
                    .accessibilityIdentifier("workspace-delete-confirm-button")

                    Button("Cancel", action: onCancel)
                        .buttonStyle(.herdrGhost())
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

// MARK: - Add pane drawer

struct AddPaneDrawer: View {
    let onAdd: (AddPaneRequest) -> Void
    let onCancel: () -> Void

    @State private var kind: AddPaneKind = .pane
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add to Space")
                .font(.jost(.title3, weight: .semibold))
            Picker("Add", selection: $kind) {
                Text("Pane").tag(AddPaneKind.pane)
                Text("Tab").tag(AddPaneKind.tab)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("pane-add-kind-picker")

            Text(kind == .pane
                 ? "Add a pane beside this one. Name is optional."
                 : "Add a tab with its own pane. Name is optional.")
                .font(.jost(.subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text(kind == .pane ? "Pane name" : "Tab name")
                    .font(.jost(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Optional", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.fieldBackground, in: RoundedRectangle.continuous(DesignSystem.CornerRadius.md))
                    .accessibilityIdentifier("pane-add-name-field")
            }

            Spacer(minLength: 8)

            VStack(spacing: 10) {
                Button(kind == .pane ? "Add Pane" : "Add Tab") {
                    onAdd(AddPaneRequest(kind: kind, name: name))
                }
                .buttonStyle(.herdrPrimary())
                .accessibilityIdentifier("pane-add-confirm-button")

                Button("Cancel", action: onCancel)
                    .buttonStyle(.herdrGhost())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backgroundGradient.ignoresSafeArea())
    }
}

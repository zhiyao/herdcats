import SwiftUI

struct PhoneAnswersWaitingRow: View {
    let agent: ApprovalAgent
    let result: AgentHooksResult?
    let onSetup: (PhoneAnswersMode) -> Void
    var body: some View {
        let hint = PhoneAnswersPresentation.hint(agent: agent, result: result)
        RecoveryNotice(title: hint.title, systemImage: "questionmark.bubble", identifier: "phone-answers-waiting") {
            if let detail = hint.detail { Text(detail) }
        } actions: {
            if let action = hint.action {
                Button(action.confirmLabel) { onSetup(action) }
            }
        }
    }
}
struct PhoneAnswersSheet: View {
    let selection: PhoneAnswersSelection
    let connection: HerdrConnection
    let store: PhoneAnswersStore
    let isCurrent: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var feedback: String?
    @State private var completed = false
    @State private var failed = false

    private var agent: ApprovalAgent? { ApprovalAgent(rawValue: selection.key.agent) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(agent.map { "\($0.displayName) approvals and questions" } ?? "Approvals and questions not available for this agent")
                        .font(.jost(.title2, weight: .semibold))
                    if let agent {
                        if selection.mode.requiresConfirmation {
                            Text("This removes the Herdcats hook and deletes recorded requests; your other hooks are untouched.")
                        } else {
                            Text("Adds one hook to \(agent.hookSettingsPath) that records requests so Herdcats can show approval requests and questions on your phone.")
                            Text("The terminal dialog still decides. Nothing is sent until you tap an option. Backups are kept.")
                            if agent == .codex { Text("Codex will ask you once, at your desk, to trust the new hook.") }
                        }
                    }
                    if !isCurrent() { Text("Reconnect to this host to continue.").foregroundStyle(Theme.textMuted) }

                }
                .font(.jost(.body))
                .padding(20)
            }
            .bottomNotice {
                if feedback != nil || busy {
                    RecoveryNotice(
                        title: failed ? "Setup needs attention" : (busy ? "Updating setup" : "Setup updated"),
                        systemImage: failed ? "exclamationmark.triangle" : (busy ? "arrow.triangle.2.circlepath" : "checkmark.bubble"),
                        identifier: "phone-answers-notice"
                    ) {
                        if let feedback {
                            Text(feedback)
                                .foregroundStyle(failed ? Theme.destructive : Theme.textMuted)
                                .accessibilityIdentifier("phone-answers-result")
                        }
                        if busy { ProgressView("Updating approvals and questions…") }
                    } actions: { EmptyView() }
                    .padding(.vertical, 4)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !completed {
                    Button(selection.mode.confirmLabel, role: selection.mode.requiresConfirmation ? .destructive : nil) { run() }
                        .buttonStyle(.herdrPrimary(tint: selection.mode.requiresConfirmation ? Theme.destructive : nil))
                        .disabled(busy || !isCurrent() || agent == nil)
                        .accessibilityIdentifier("phone-answers-confirm")
                        .padding(16)
                }
            }
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(busy)
    }
    @MainActor private func run() {
        guard !busy, isCurrent(), let agent else { return }
        busy = true; feedback = nil; failed = false
        Task { @MainActor in
            defer { busy = false }
            do {
                guard isCurrent(), await connection.bridgeCapabilities(for: selection.key.generation)?.approvals == true,
                    isCurrent() else { throw HerdrError.notConnected }
                let result: AgentHooksResult
                if selection.mode.requiresConfirmation {
                    result = try await connection.uninstallHooks(agent: agent, target: selection.key.target, owned: selection.key.generation)
                } else {
                    result = try await connection.installHooks(agent: agent, target: selection.key.target, owned: selection.key.generation)
                }
                guard isCurrent() else { return }
                failed = !PhoneAnswersPresentation.succeeded(mode: selection.mode, result: result)
                completed = !failed
                if failed { feedback = "Couldn't update approvals and questions. Check the host, then try again." }
                else if selection.mode.requiresConfirmation { feedback = "Approvals and questions turned off." }
                else if agent == .codex { feedback = "Hook installed. Approve it once in Codex at your desk." }
                else { feedback = "Approvals and questions are set up." }
                store.invalidate(selection.key)
                await store.check(selection.key) {
                    guard isCurrent() else { throw HerdrError.notConnected }
                    return try await connection.hooksStatus(agent: agent, target: selection.key.target, owned: selection.key.generation)
                }
            } catch {
                guard isCurrent() else { return }
                failed = true
                feedback = "Couldn't update approvals and questions. Check the host, then try again."
                store.invalidate(selection.key)
                await store.check(selection.key) {
                    guard isCurrent() else { throw HerdrError.notConnected }
                    return try await connection.hooksStatus(agent: agent, target: selection.key.target, owned: selection.key.generation)
                }
            }
        }
    }
}

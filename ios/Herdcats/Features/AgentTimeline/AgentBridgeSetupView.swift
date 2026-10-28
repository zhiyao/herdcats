import SwiftUI
import UIKit

// MARK: - Agent bridge setup view

/// Explicit opt-in installation on the displayed SSH endpoint; manual setup stays available.
struct AgentBridgeSetupView: View {
    var reason: HostHelperSetupReason = .missing
    var agent: String? = nil
    var installedVersion: String? = nil
    var pinnedVersion: String = HostHelperSetupPlan.version
    let isChecking: Bool
    let feedback: String?
    let stage: HostHelperSetupStage
    let target: ConnectionIdentity
    let canInstall: Bool
    let onInstall: () -> Void
    let onCheckAgain: () -> Void
    let onUseTerminal: () -> Void
    @State private var copied = false
    private var command: String {
        HostHelperSetupPlan.manualInstallCommand(reason: reason, pinnedVersion: pinnedVersion)
    }
    private var installLabel: String {
        HostHelperSetupPlan.installLabel(stage: stage, reason: reason, pinnedVersion: pinnedVersion)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if reason == .updateRequired {
                        Image(systemName: "arrow.up.circle")
                            .font(.system(size: 36)).foregroundStyle(Theme.text)
                        Text(HostHelperProbe.isAtLeastMinimum(installedVersion)
                             ? "A newer Herdcats Bridge is available"
                             : "Upgrade Herdcats Bridge to continue")
                            .font(.jost(.title, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(AgentTimelineView.upgradePitch(agent: agent, installedVersion: installedVersion, pinnedVersion: pinnedVersion))
                            .font(.jost(.body)).foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(target.username)@\(target.host)")
                                .font(.jost(.subheadline, weight: .semibold))
                            Text("~/.local/bin/herdcats-bridge")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                            Text("Port \(target.port)")
                                .font(.jost(.caption))
                                .foregroundStyle(Theme.textMuted)
                            let versionRow = (installedVersion?.isEmpty == false)
                                ? "\(installedVersion!) → \(pinnedVersion)"
                                : "→ \(pinnedVersion)"
                            Text(versionRow)
                                .font(.jost(.caption))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                        Text("Tapping Upgrade downloads \(pinnedVersion), verifies its checksum, and replaces the copy at the location shown. No sudo, background service, or agent hooks are required.")
                            .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                    } else {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 36)).foregroundStyle(Theme.text)
                        Text("A clearer view of your agent")
                            .font(.jost(.title, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text("Timeline turns your agent session into readable messages and tool activity, with colors that match your app.")
                            .font(.jost(.body)).foregroundStyle(Theme.textMuted)
                        VStack(alignment: .leading, spacing: 14) {
                            benefit("Read comfortably in light or dark mode", icon: "circle.lefthalf.filled")
                            benefit("Follow messages and review activity summaries", icon: "text.alignleft")
                            benefit("Send prompts with Compose, voice, and photos", icon: "square.and.pencil")
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 12) {
                            Text("How Herdcats Bridge works")
                                .font(.jost(.headline)).accessibilityAddTraits(.isHeader)
                            Text("Herdcats Bridge is a small program on your SSH computer that reads your existing agent session and sends its history to Herdcats over your SSH connection. Your agent keeps running in the same pane.")
                                .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                            Text("It runs only while Timeline is open. There’s no background service or agent hook to configure.")
                                .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(target.username)@\(target.host)")
                                .font(.jost(.subheadline, weight: .semibold))
                            Text("~/.local/bin/herdcats-bridge")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.textMuted)
                            Text("Port \(target.port) · Herdcats Bridge \(pinnedVersion)")
                                .font(.jost(.caption))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
                        Text("Tapping Install downloads the pinned Herdcats Bridge release and verifies its checksum before running the installer. No sudo, background service, or agent hooks are required.")
                            .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                        if agent == "pi" {
                            Text("Pi also requires the Herdcats Pi extension in this pane’s Pi 1.4.0 TUI. The bridge installer does not install or enable the extension.")
                                .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                            Link("Pi extension setup", destination: URL(string: "https://github.com/zhiyao/herdcats/releases/tag/herdcats-bridge-v\(pinnedVersion)")!)
                                .font(.jost(.subheadline))
                        }
                    }

                    DisclosureGroup("Manual setup") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Set it up once on your SSH host")
                                .font(.jost(.headline)).accessibilityAddTraits(.isHeader)
                            Button {
                                UIPasteboard.general.string = command
                                copied = true
                            } label: {
                                Label(copied ? "Command copied" : "Copy install command", systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.herdrSecondary)
                            .accessibilityIdentifier("timeline-helper-copy-command")
                            Text("1. Copy the command below.\n2. Run it on the computer where Herdr and your agent are running.\n3. Come back here and tap Check again.")
                                .font(.jost(.subheadline)).foregroundStyle(Theme.textMuted)
                            Button(action: onCheckAgain) {
                                HStack {
                                    if isChecking { ProgressView() }
                                    Text(isChecking ? "Checking…" : "Check again")
                                }.frame(maxWidth: .infinity)
                            }
                            .disabled(isChecking || stage.isBusy).buttonStyle(.herdrSecondary)
                            .accessibilityIdentifier("timeline-helper-check-again")
                            Text(command)
                                .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 16))
                            Text(reason == .updateRequired
                                ? "The installer checks the download and replaces Herdcats Bridge in your user account. The command includes `--replace`."
                                : "The installer checks the download and installs in your user account.")
                                .font(.jost(.caption)).foregroundStyle(Theme.textMuted)
                            Link("View downloads and setup details", destination: URL(string: "https://github.com/zhiyao/herdcats/releases")!)
                                .font(.jost(.subheadline))
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(24)
            }
            .accessibilityIdentifier("timeline-setup-scroll")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let feedback {
                        Text(feedback).font(.jost(.caption)).foregroundStyle(Theme.textMuted)
                            .accessibilityIdentifier("timeline-setup-feedback")
                    }
                    Button(action: onInstall) {
                        HStack {
                            if stage.isBusy { ProgressView() }
                            Text(installLabel)
                        }.frame(maxWidth: .infinity)
                    }
                    .disabled(stage.isBusy || isChecking || !canInstall)
                    .buttonStyle(.herdrPrimary)
                    .accessibilityIdentifier("timeline-helper-install")
                    if !canInstall {
                        Button(action: onCheckAgain) {
                            HStack {
                                if isChecking { ProgressView() }
                                Text(isChecking ? "Checking…" : "Check again")
                            }.frame(maxWidth: .infinity)
                        }
                        .disabled(isChecking || stage.isBusy).buttonStyle(.herdrSecondary)
                        .accessibilityIdentifier("timeline-helper-check-again")
                    }
                    Button("Use Terminal for now", action: onUseTerminal)
                        .buttonStyle(.herdrSecondary)
                        .accessibilityIdentifier("timeline-helper-use-terminal")
                }
                .padding(20).background(Theme.background)
            }
            .background(Theme.background).foregroundStyle(Theme.text)
            .navigationTitle(reason == .updateRequired ? "Upgrade Herdcats Bridge" : "Set up Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onUseTerminal) { Image(systemName: "xmark") }
                        .accessibilityLabel("Use Terminal for now")
                        .accessibilityIdentifier("timeline-helper-dismiss")
                }
            }
        }
    }
    private func benefit(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.jost(.subheadline))
    }
}

// MARK: - Codex daemon confirm sheet

struct CodexDaemonConfirmSheet: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Codex's shared background server only remembers the terminal that started it, so Herdcats can't tell which pane this conversation belongs to. Turning it off lets Herdcats identify this pane's session.")
                        .font(.jost(.body))
                        .foregroundStyle(Theme.text)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("What happens")
                            .font(.jost(.headline))
                        Text("Sets `daemon_auto_start = false` in ~/.codex/config.toml (a backup is made first), then stops Codex's shared background server and its updater on this computer.")
                            .font(.jost(.subheadline))
                            .foregroundStyle(Theme.textMuted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cost")
                            .font(.jost(.headline))
                        Text("Every Codex session using the shared server disconnects. Restart those sessions; new ones start without it.")
                            .font(.jost(.subheadline))
                            .foregroundStyle(Theme.textMuted)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Undo")
                            .font(.jost(.headline))
                        Text("codex features enable daemon_auto_start")
                            .font(.system(.footnote, design: .monospaced))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Safety")
                            .font(.jost(.headline))
                        Text("Herdcats only stops processes it can confirm belong to Codex; anything else is left running.")
                            .font(.jost(.subheadline))
                            .foregroundStyle(Theme.textMuted)
                    }

                    Link("Learn more", destination: URL(string: "https://herdcats.dev/support/#using-app-codex-shared-background-server")!)
                        .font(.jost(.subheadline))
                }
                .padding(20)
            }
            .navigationTitle("Turn off shared server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Turn off", role: .destructive) { onConfirm() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

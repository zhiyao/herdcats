import SwiftUI
import UIKit

extension SettingsScreen {

    var refreshSection: some View {
        Section {
            Toggle(isOn: $model.autoRefreshEnabled.animation()) {
                Label("Auto-refresh (5s)", systemImage: "arrow.triangle.2.circlepath")
            }
            .listRowBackground(Theme.cardBackground)

            if !model.autoRefreshEnabled {
                Button {
                    Task { await model.refresh(appModel.connection) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .listRowBackground(Theme.cardBackground)
            }
        } header: {
            Text("Refresh")
                .font(.jost(.footnote))
        }
    }

    var panePrivacySection: some View {
        Section {
            Toggle(isOn: paneContentSavingBinding) {
                Label("Preserve Drafts and Command History", systemImage: "text.alignleft")
            }
            .listRowBackground(Theme.cardBackground)

            Button(role: .destructive) {
                confirmClearPaneContent = true
            } label: {
                Label("Clear Saved Drafts and History", systemImage: "trash")
            }
            .listRowBackground(Theme.cardBackground)
        } header: {
            Text("Pane Data & Privacy")
                .font(.jost(.footnote))
        } footer: {
            Text(
                "Preserves unsent prompts and voice dictations when switching panes or backgrounding the app, and remembers recent commands. Stored strictly on this iPhone—turn off to keep inputs in temporary memory only."
            )
                .font(.jost(.footnote))
        }
    }

    var themeSection: some View {
        Section {
            Picker("Appearance", selection: appearance) {
                ForEach(AppearancePreference.allCases) { preference in
                    Text(preference.title)
                        .tag(preference)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.cardBackground)
        } header: {
            Text("Appearance")
                .font(.jost(.footnote))
        }
    }

    var paneSection: some View {
        Section {
            Toggle(isOn: $showComposeByDefault) {
                Label("Show Compose by Default", systemImage: "square.and.pencil")
            }
            .listRowBackground(Theme.cardBackground)
            .accessibilityIdentifier("pane-show-compose-toggle")

            Picker("Pane Text", selection: paneTextSize) {
                ForEach(PaneTextSizePreference.allCases) { preference in
                    Text(preference.title)
                        .tag(preference)
                        .accessibilityLabel(preference.accessibilityTitle)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.cardBackground)

            Text("The quick brown fox jumps over the lazy dog")
                .font(paneTextSize.wrappedValue.outputFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Theme.cardBackground)
                .accessibilityLabel("Pane Text Preview")

            VStack(alignment: .leading, spacing: 8) {
                Text("When Agent Writes")
                Picker("When Agent Writes", selection: paneScrollBehavior) {
                    ForEach(PaneScrollBehaviorPreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(paneScrollBehavior.wrappedValue.detail)
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Theme.cardBackground)

            VStack(alignment: .leading, spacing: 8) {
                Text("Mark as Read")
                Picker("Mark as Read", selection: doneClear) {
                    ForEach(DoneClearPreference.allCases) { preference in
                        Text(preference.title)
                            .tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(doneClear.wrappedValue.detail)
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Theme.cardBackground)
        } header: {
            Text("Pane")
                .font(.jost(.footnote))
        }
    }

    var soundSection: some View {
        Section {
            Picker(selection: doneSound) {
                ForEach(AgentAlertSound.allCases) { sound in
                    Text(sound.title).tag(sound)
                }
            } label: {
                Label("Agent Done", systemImage: "checkmark.circle")
            }
            .listRowBackground(Theme.cardBackground)

            Picker(selection: blockedSound) {
                ForEach(AgentAlertSound.allCases) { sound in
                    Text(sound.title).tag(sound)
                }
            } label: {
                Label("Agent Blocked", systemImage: "exclamationmark.triangle")
            }
            .listRowBackground(Theme.cardBackground)

            Toggle(isOn: hapticBinding) {
                Label("Haptic Feedback", systemImage: "iphone.radiowaves.left.and.right")
            }
            .listRowBackground(Theme.cardBackground)
            .accessibilityIdentifier("haptic-toggle")
        } header: {
            Text("Sounds & Haptics")
                .font(.jost(.footnote))
        } footer: {
            Text("Alerts play while the app is open and respect the Ring/Silent switch.")
                .font(.jost(.footnote))
        }
    }

    var launchSection: some View {
        Section {
            Picker(selection: launch) {
                ForEach(LaunchPreference.allCases) { preference in
                    Label(preference.title, systemImage: preference.systemImage)
                        .tag(preference)
                }
            } label: {
                Text("On Launch")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .listRowBackground(Theme.cardBackground)
        } header: {
            Text("On Launch")
                .font(.jost(.footnote))
        }
    }

    var connectionSection: some View {
        Section {
            if let machine = appModel.selectedMachine {
                Label(machine.label, systemImage: "desktopcomputer")
                    .listRowBackground(Theme.cardBackground)
                Text("\(machine.target) · \(machine.session)")
                    .font(.jost(.caption))
                    .listRowBackground(Theme.cardBackground)
            }
            if case let .connected(host, username) = appModel.machineCatalog.phase {
                Label("\(username)@\(host)", systemImage: "link")
                    .listRowBackground(Theme.cardBackground)
            } else if case let .offline(host, username) = appModel.machineCatalog.phase {
                Label("\(username)@\(host) (offline)", systemImage: "link.badge.plus")
                    .listRowBackground(Theme.cardBackground)
            }

            if let version = appModel.herdrVersion {
                Label(version, systemImage: "shippingbox")
                    .listRowBackground(Theme.cardBackground)
            }

            Button(role: .destructive) {
                Task { await appModel.disconnect() }
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .listRowBackground(Theme.cardBackground)
        } header: {
            Text("Connection")
                .font(.jost(.footnote))
        }
    }

    var versionSection: some View {
        Section {
            NavigationLink {
                LicensesView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            .listRowBackground(Theme.cardBackground)

            HStack {
                Spacer()
                Text("Herdcats \(Self.appVersion)")
                    .font(.jost(.footnote))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }
}

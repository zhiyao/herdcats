import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ConnectionSettingsView {
    var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Host + port
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Host")
                HStack(spacing: 10) {
                    TextField("192.168.1.42", text: $host)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.primary)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    fieldLabel("Port", hidden: true)
                    TextField("22", text: $port)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.primary)
                        .keyboardType(.numberPad)
                        .frame(width: 64)
                }
            }
            .padding(12)
            .background(fieldShape.fill(Theme.fieldBackground))

            // Username
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Username")
                TextField("whoami", text: $username)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(12)
            .background(fieldShape.fill(Theme.fieldBackground))

            // Auth mode
            Picker("Authentication", selection: $authModeRaw) {
                ForEach(AuthMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)

            switch authMode {
            case .password:
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Password")
                    HStack(spacing: 8) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textFieldStyle(.plain)
                        .foregroundStyle(.primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(.jost(14, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(fieldShape.fill(Theme.fieldBackground))

            case .privateKey:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        fieldLabel("OpenSSH Private Key (ed25519)")
                        Spacer()
                        if !keyPEM.isEmpty {
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.jost(14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showKey ? "Hide Private Key" : "Show Private Key")
                        }
                    }

                    Group {
                        if showKey {
                            TextEditor(text: $keyPEM)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(minHeight: 92)
                                .scrollContentBackground(.hidden)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        } else if keyPEM.isEmpty {
                            TextEditor(text: $keyPEM)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(minHeight: 92)
                                .scrollContentBackground(.hidden)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .overlay(alignment: .topLeading) {
                                    Text("Paste OpenSSH private key or tap Import…")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 8)
                                        .allowsHitTesting(false)
                                }
                        } else {
                            Text(maskedPrivateKey)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    showKey = true
                                }
                        }
                    }
                    .padding(8)
                    .herdrField()
                    .overlay(fieldShape.stroke(Theme.hairline, lineWidth: 1))
                    HStack {
                        Button {
                            keyImporterPresented = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.herdrSecondary(fullWidth: false))
                        .controlSize(.small)

                        Spacer()

                        Link(destination: Self.documentationURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "questionmark.circle")
                                Text("SSH Setup Guide")
                                Image(systemName: "arrow.up.right")
                                    .font(.jost(8, weight: .semibold))
                            }
                            .font(.jost(.caption))
                            .foregroundStyle(Theme.accent)
                        }
                    }
                    if keyIsEncrypted {
                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("Key Passphrase")
                            SecureField("Enter key passphrase", text: $keyPassphrase)
                                .textFieldStyle(.plain)
                                .foregroundStyle(.primary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .accessibilityLabel("Key passphrase")
                                .padding(12)
                                .herdrField()
                                .overlay(fieldShape.stroke(Theme.hairline, lineWidth: 1))
                        }
                        if remember {
                            Toggle("Remember Passphrase", isOn: $rememberPassphrase)
                                .font(.jost(.footnote))
                                .tint(Theme.accent)
                        }
                        Text("The key is unlocked on this device. Remember the passphrase to reconnect after restarting the app.")
                            .font(.jost(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    if let importError = importErrorMessage {
                        Text(importError)
                            .font(.jost(.caption2))
                            .foregroundStyle(Theme.destructive)
                    }
                    if let pubKey = derivedPublicKey {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Matching public key (required in ~/.ssh/authorized_keys):")
                                .font(.jost(11, weight: .medium))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Text(pubKey)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    UIPasteboard.general.string = pubKey
                                    didCopyPubKey = true
                                    Task {
                                        try? await Task.sleep(for: .seconds(2))
                                        didCopyPubKey = false
                                    }
                                } label: {
                                    Label(
                                        didCopyPubKey ? "Copied" : "Copy Key",
                                        systemImage: didCopyPubKey ? "checkmark" : "doc.on.doc"
                                    )
                                }
                                .buttonStyle(.herdrSecondary(fullWidth: false))
                                .controlSize(.mini)
                                .accessibilityLabel(didCopyPubKey ? "Copied" : "Copy Public Key")
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle.continuous(DesignSystem.CornerRadius.sm)
                                    .fill(Theme.subtleFill)
                            )
                        }
                    } else if let error = keyValidationError {
                        Text(error)
                            .font(.jost(.caption2))
                            .foregroundStyle(Theme.warning)
                    }
                }
                .fileImporter(
                    isPresented: $keyImporterPresented,
                    allowedContentTypes: [.item, .data, .plainText],
                    allowsMultipleSelection: false
                ) { result in
                    handleKeyImport(result)
                }
                .onChange(of: keyPEM) { _, _ in
                    importErrorMessage = nil
                    keyPassphrase = ""
                    rememberPassphrase = false
                }
            }

            Toggle("Remember on This Device", isOn: $remember)
                .font(.jost(.footnote))
                .tint(Theme.accent)

            // Connect button
            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if appModel.isConnecting {
                        CircularArcSpinner(size: 16)
                    }
                    Text(appModel.isConnecting ? "Connecting…" : "Connect")
                }
            }
            .buttonStyle(.herdrPrimary())
            .disabled(!canConnect || appModel.isConnecting)
        }
        .disabled(appModel.isConnecting)
        .padding(18)
        .background(
            RoundedRectangle.continuous(DesignSystem.CornerRadius.xl)
                .fill(Theme.cardBackground)
        )
    }
}

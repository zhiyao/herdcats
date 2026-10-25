import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ConnectionSettingsView {
    var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Name (optional)")
                TextField("Name (optional)", text: $name)
                    .textFieldStyle(.plain)
            }
            .padding(12)
            .background(fieldShape.fill(Theme.fieldBackground))

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Host")
                    TextField("192.168.1.42", text: $host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Port")
                    TextField("22", text: $port).keyboardType(.numberPad)
                        .accessibilityLabel("Port")
                }
                .frame(width: 76)
            }
            .textFieldStyle(.plain)
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
                    Button {
                        keyImporterPresented = true
                    } label: {
                        Label("Import Private Key…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.herdrSecondary(fullWidth: false))
                    if !keyPEM.isEmpty {
                        Label(keyValidationError == nil
                              ? (keyIsEncrypted ? "Encrypted ed25519 key loaded" : "ed25519 key loaded")
                              : "Check private key", systemImage: "key")
                            .font(.jost(.subheadline))
                    }
                    DisclosureGroup("Paste or edit private key") {
                        TextEditor(text: $keyPEM)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 110)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("Private key")
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
                            Toggle("Save passphrase on this iPhone", isOn: $rememberPassphrase)
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
                        DisclosureGroup("Public key setup") {
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

            Toggle("Save credentials on this iPhone", isOn: $remember)
                .font(.jost(.footnote))
                .tint(Theme.accent)

        }
        .disabled(isConnecting)

    }
}

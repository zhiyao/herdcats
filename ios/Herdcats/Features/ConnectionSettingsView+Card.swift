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
            .modifier(ConnectionInputSurface())

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
            .modifier(ConnectionInputSurface())

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
            .modifier(ConnectionInputSurface())

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
                .modifier(ConnectionInputSurface())

            case .privateKey:
                VStack(alignment: .leading, spacing: 8) {
                    ConnectionPrivateKeyField(key: $keyPEM) { keyImporterPresented = true }
                    if !keyPEM.isEmpty {
                        Label(keyValidationError == nil
                              ? (keyIsEncrypted ? "Encrypted ed25519 key loaded" : "ed25519 key loaded")
                              : "Check private key", systemImage: "key")
                            .font(.jost(.subheadline))
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
                        }
                        .padding(12)
                        .modifier(ConnectionInputSurface())
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

/// Connection-only field surface: lifted from the sheet canvas in every palette.
struct ConnectionInputSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle.continuous(DesignSystem.CornerRadius.md)
        content
            .background(shape.fill(Theme.cardBackground))
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1).allowsHitTesting(false))
    }
}

/// Keep the field visible without placing hidden key material in the view tree.
struct ConnectionPrivateKeyField: View {
    @Binding var key: String
    let onImport: () -> Void
    @State private var revealed = false
    @FocusState private var editing: Bool
    @ScaledMetric(relativeTo: .footnote) private var fontSize: CGFloat = 13

    // TextEditor uses an eight-point text-container inset above and below its lines.
    private var bodyHeight: CGFloat {
        ceil(UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular).lineHeight * 3) + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("SSH private key")
                    .font(.jost(.subheadline, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    editing = false
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel(revealed ? "Hide Private Key" : "Show Private Key")
                .accessibilityValue(revealed ? "Visible" : "Hidden")
                Button {
                    editing = false
                    revealed = false
                    onImport()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Import Private Key")
            }
            Group {
                if revealed {
                    TextEditor(text: $key)
                        .font(.system(size: fontSize, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($editing)
                        .accessibilityLabel("Private key")
                } else {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        Text(key.isEmpty ? "Reveal to paste or edit, or import a private key." : "••••••••\n••••••••\n••••••••")
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                    }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(key.isEmpty ? "Private key input" : "Private key hidden")
                        .accessibilityValue(key.isEmpty ? "Empty" : "Hidden")
                        .accessibilityHint("Use Show Private Key to edit.")
                }
            }
            .frame(height: bodyHeight)
            .accessibilityIdentifier("connection-private-key-body")
        }
        .padding(12)
        .modifier(ConnectionInputSurface())
    }
}

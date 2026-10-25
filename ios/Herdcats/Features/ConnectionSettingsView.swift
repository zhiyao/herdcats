import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ConnectionSettingsView: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.dismiss) var dismiss
    let isReplay: Bool
    let switcher: ActiveMachine?
    @State var switchConnectionError: String?
    @State var isSwitching = false
    @State private var pendingSubmission: Submission?

    private struct Submission {
        let entry: RecentConnection
        let config: ConnectionConfig
        let rememberPassphrase: Bool
    }

    var isConnecting: Bool { switcher == nil ? appModel.isConnecting : isSwitching }
    @State var name = ""
    @State var host = ""
    @State var port = "22"
    @State var username = ""
    @State var authModeRaw = AuthMode.password.rawValue
    @State var remember = true

    @State var password = ""
    @State var keyPEM = ""
    @State var keyPassphrase = ""
    @State var rememberPassphrase = false

    var keyIsEncrypted: Bool { (try? OpenSSHEd25519.isEncrypted(pem: keyPEM)) == true }
    @State var showPassword = false
    @State var showKey = false
    @State var keyImporterPresented = false
    @State var importErrorMessage: String?
    @State var didCopyPubKey = false
    @State var showingSetupGuide = false

    var derivedPublicKey: String? {
        try? OpenSSHEd25519.openSSHPublicKeyString(for: validatedPublicKey())
    }

    private func validatedPublicKey() throws -> Data {
        // Validate plaintext private material before enabling Connect. Encrypted
        // keys expose metadata here; unlock them only during the connection attempt.
        if try !OpenSSHEd25519.isEncrypted(pem: keyPEM) {
            _ = try OpenSSHEd25519.parseRawPrivateKey(pem: keyPEM)
        }
        return try OpenSSHEd25519.parsePublicKey(pem: keyPEM)
    }

    var maskedPrivateKey: String {
        OpenSSHEd25519.maskPrivateKey(pem: keyPEM)
    }

    var keyValidationError: String? {
        let trimmed = keyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("ssh-ed25519 ") || trimmed.hasPrefix("ssh-rsa ") || trimmed.hasPrefix("ecdsa-") {
            return "This is an SSH public key (.pub). Please import or paste your private key instead "
                + "(usually named herdcats_key or id_ed25519 without .pub)."
        }
        if trimmed.contains("BEGIN RSA PRIVATE KEY")
            || trimmed.contains("BEGIN DSA PRIVATE KEY")
            || trimmed.contains("BEGIN EC PRIVATE KEY") {
            return "This key uses an unsupported format. Herdcats requires an ed25519 OpenSSH key "
                + "(ssh-keygen -t ed25519)."
        }
        do {
            _ = try validatedPublicKey()
            return nil
        } catch let keyError as OpenSSHKeyError {
            return keyError.errorDescription
        } catch {
            return error.localizedDescription
        }
    }

    static let documentationURL = URL(string: "https://herdcats.dev/support/#connect")!

    init(connection: RecentConnection, isReplay: Bool = false, switcher: ActiveMachine? = nil) {
        self.isReplay = isReplay
        self.switcher = switcher
        _name = State(initialValue: connection.name ?? "")
        _host = State(initialValue: connection.host)
        _port = State(initialValue: String(connection.port))
        _username = State(initialValue: connection.username)
        _authModeRaw = State(initialValue: connection.authMode)
        _remember = State(initialValue: connection.remember)
        let secret = connection.remember
            ? (try? KeychainStore.load(account: connection.secretAccount)) ?? "" : ""
        _password = State(initialValue: connection.authMode == "password" ? secret : "")
        _keyPEM = State(initialValue: connection.authMode == "privateKey" ? secret : "")
        let phrase = connection.remember ? (try? KeychainStore.load(account: connection.secretAccount + ".passphrase")) ?? "" : ""
        _keyPassphrase = State(initialValue: phrase)
        _rememberPassphrase = State(initialValue: !phrase.isEmpty)
    }

    enum AuthMode: String, CaseIterable, Identifiable {
        case password
        case privateKey

        var id: String { rawValue }
        var title: String {
            switch self {
            case .password: "Password"
            case .privateKey: "Private Key"
            }
        }
    }

    var authMode: AuthMode {
        AuthMode(rawValue: authModeRaw) ?? .password
    }

    var portNumber: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    var canConnect: Bool {
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty,
              !username.trimmingCharacters(in: .whitespaces).isEmpty,
              portNumber != nil else { return false }
        switch authMode {
        case .password:
            return !password.isEmpty
        case .privateKey:
            return derivedPublicKey != nil && (!keyIsEncrypted || !keyPassphrase.isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let error = switchConnectionError {
                        ErrorBanner(message: error)
                    } else if switcher == nil, let error = appModel.lastError {
                        if appModel.herdrMissingOnLastConnect {
                            MissingHerdrRecoveryCard(inForm: true) { showingSetupGuide = true }
                        } else if appModel.herdrSessionUnavailableOnLastConnect {
                            SessionRecoveryCard(inForm: true)
                        } else {
                            ErrorBanner(message: error)
                        }
                    }
                    connectionCard
                    footer
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.backgroundGradient)
            .navigationTitle("Connection Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.jost(16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close")
                    .disabled(isConnecting)
                }
            }
        }
        .overlay {
            // A sheet is presented above the root view, so it needs its own
            // loading surface while authentication and the Herdr check run.
            if isConnecting {
                LazyCatLoadingView(message: switcher?.pending?.connectionProgressMessage ?? appModel.connectionProgressMessage)
                    .background(Theme.backgroundGradient.ignoresSafeArea())
            }
        }
        .hostKeyApprovalSheet {
            await connect()
        }
        .background {
            if let switcher, let pending = switcher.pending {
                Color.clear
                    .frame(width: 0, height: 0)
                    .hostKeyApprovalSheet(onCancelled: {
                        guard switcher.pending === pending else { return }
                        await switcher.cancelSwitch()
                        pendingSubmission = nil
                    }, onApproved: {
                        guard switcher.pending === pending, let submission = pendingSubmission else { return }
                        isSwitching = true
                        defer { isSwitching = false }
                        let outcome = await switcher.finishPendingSwitch()
                        handleSwitchOutcome(outcome, submission: submission)
                    })
                    .environment(pending)
                    .id(ObjectIdentifier(pending))
            }
        }
        .onAppear { switcher?.pendingHostKeyOwnedByForm = true }
        .onDisappear { switcher?.pendingHostKeyOwnedByForm = false }
        .sheet(isPresented: $showingSetupGuide) {
            HerdrSetupGuideView()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isConnecting)
    }

    var footer: some View {
        VStack(spacing: 8) {
            Text("Use a host address your iPhone can reach. 127.0.0.1 means the iPhone itself.")
                .font(.jost(.footnote))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Connection Setup Help") { showingSetupGuide = true }
                .font(.jost(.footnote))
        }
        .padding(.horizontal, 18)
    }

    // MARK: Helpers

    var fieldShape: some Shape {
        RoundedRectangle.continuous(DesignSystem.CornerRadius.md)
    }

    func fieldLabel(_ text: String, hidden: Bool = false) -> some View {
        Group {
            if !hidden {
                Text(text.uppercased())
                    .font(.jost(10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .tracking(0.8)
            }
        }
    }

    func handleKeyImport(_ result: Result<[URL], Error>) {
        importErrorMessage = nil
        switch result {
        case let .failure(error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                return
            }
            importErrorMessage = "File selection failed: \(error.localizedDescription)"
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
                    importErrorMessage = "Unable to read key: file is not UTF-8 or ASCII text."
                    return
                }
                keyPEM = content.trimmingCharacters(in: .whitespacesAndNewlines)
                showKey = false
            } catch {
                importErrorMessage = "Could not read file: \(error.localizedDescription)"
            }
        }
    }

    private func showConnectionError(_ message: String) {
        if switcher != nil {
            switchConnectionError = message
        } else {
            appModel.lastError = message
        }
    }

    func connect() async {
        guard !isConnecting else { return }
        switchConnectionError = nil
        isSwitching = switcher != nil
        defer { isSwitching = false }
        let config = ConnectionConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            port: portNumber ?? 22,
            username: username.trimmingCharacters(in: .whitespaces),
            auth: {
                switch authMode {
                case .password: .password(password)
                case .privateKey: .privateKey(keyPEM, passphrase: keyIsEncrypted ? keyPassphrase : nil)
                }
            }()
        )

        let loaded = (try? RecentConnectionStore.load()) ?? []
        let entry = RecentConnectionStore.entry(
            host: config.host, port: config.port, username: config.username,
            authMode: authModeRaw, remember: remember, name: name, in: loaded
        )
        if !isReplay {
            do {
                if !remember {
                    try KeychainStore.delete(account: entry.secretAccount)
                    try KeychainStore.delete(account: entry.secretAccount + ".passphrase")
                    // Keep saved metadata in sync even if the connection attempt fails.
                    try RecentConnectionStore.disableRemembering(entry)
                }
                // When remember stays on but the passphrase is no longer wanted, its
                // deletion is deferred to after a successful connection: deleting here
                // would strand a still-saved encrypted-key profile without the passphrase
                // it needs if the connection attempt fails.
            } catch {
                showConnectionError(error.localizedDescription)
                return
            }
        }
        let submission = Submission(entry: entry, config: config, rememberPassphrase: rememberPassphrase)
        if let switcher {
            pendingSubmission = submission
            let outcome = await switcher.switchMachine(to: entry, config: config)
            handleSwitchOutcome(outcome, submission: submission)
        } else {
            await appModel.connect(config: config)
            guard case .connected = appModel.phase else { return }
            persistAndDismiss(submission)
        }
    }

    private func handleSwitchOutcome(_ outcome: ActiveMachine.SwitchOutcome, submission: Submission) {
        guard let switcher else { return }
        switch outcome {
        case .switched:
            persistAndDismiss(submission)
        case .failed:
            if switcher.pending?.hostKeyChallenge == nil {
                switchConnectionError = switcher.switchError ?? "Connection failed"
                switcher.switchError = nil
                pendingSubmission = nil
            }
        case .alreadyActive:
            dismiss()
        case .needsCredentials, .superseded:
            pendingSubmission = nil
        }
    }

    private func persistAndDismiss(_ submission: Submission) {
        let entry = submission.entry
        if !isReplay {
            do {
                if entry.remember {
                    switch submission.config.auth {
                    case let .password(secret):
                        try KeychainStore.save(secret, account: entry.secretAccount)
                        try KeychainStore.delete(account: entry.secretAccount + ".passphrase")
                    case let .privateKey(secret, passphrase):
                        try KeychainStore.save(secret, account: entry.secretAccount)
                        if submission.rememberPassphrase, let passphrase {
                            try KeychainStore.save(passphrase, account: entry.secretAccount + ".passphrase")
                        } else {
                            try KeychainStore.delete(account: entry.secretAccount + ".passphrase")
                        }
                    }
                }
                _ = try RecentConnectionStore.record(entry, in: RecentConnectionStore.load())
            } catch {
                showConnectionError(error.localizedDescription)
                return
            }
        }
        dismiss()
    }

}

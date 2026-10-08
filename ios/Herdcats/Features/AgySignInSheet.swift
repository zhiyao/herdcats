import SafariServices
import SwiftUI

@MainActor
struct AgySignInSheet: View {
    let model: SpacesModel
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var sessionID = UUID()
    @State private var transcript = AgySignInTranscript()
    @State private var code = ""
    @State private var error: String?
    @State private var isRunning = false
    @State private var isSending = false
    @State private var isChecking = false
    @State private var browser: SignInBrowserLink?
    @State private var loginTask: Task<Void, Never>?
    @State private var inputTask: Task<Void, Never>?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Sign in to Agy on the remote machine. Open the sign-in page, then paste its authorization code here.")
                        .foregroundStyle(.secondary)

                    if let error {
                        Text(error).foregroundStyle(.red)
                    }

                    if transcript.codeSubmitted {
                        Label("Code Sent to Agy", systemImage: "checkmark.circle")
                        Text("Check quota to confirm that sign-in completed.")
                            .foregroundStyle(.secondary)
                    } else {
                        if let url = transcript.authorizationURL {
                            Button {
                                browser = SignInBrowserLink(url: url)
                            } label: {
                                Label("Open Sign-in Page", systemImage: "safari")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Text(url.host ?? "Google")
                                .font(.jost(.caption)).foregroundStyle(.secondary)
                        }

                        if transcript.showsCodeEntry {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Authorization Code")
                                    .font(.jost(.headline))
                                SecureField("Authorization code", text: $code,
                                            prompt: Text("Tap here to enter your code").foregroundStyle(.secondary))
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.plain)
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 48)
                                    .background(Theme.fieldBackground, in: RoundedRectangle.continuous(DesignSystem.CornerRadius.sm))
                                    .accessibilityIdentifier("agy-authorization-code")
                            }
                            HStack {
                                PasteButton(payloadType: String.self) { values in
                                    guard let value = values.first else { return }
                                    code = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                                .accessibilityIdentifier("agy-paste-code")
                                Button("Submit Code") { send(.code(code)) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !transcript.awaitingCode || !isRunning || isSending)
                            }
                            Text(codeSubmissionStatus)
                                .font(.jost(.callout))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("agy-code-status")
                            if !isRunning {
                                Button("Restart Sign-in") { start() }
                                    .buttonStyle(.bordered)
                                    .disabled(isChecking)
                            }
                        } else if isRunning && transcript.isChoosingLoginMethod {
                            Text("Choose a login method with Up and Down, then tap Enter at the bottom of the screen.")
                                .font(.jost(.callout)).foregroundStyle(.secondary)
                        }

                        if transcript.displayText.isEmpty {
                            if isRunning { CircularArcSpinner("Starting Agy…") }
                        } else if transcript.showsCodeEntry {
                            DisclosureGroup("Terminal Details") {
                                terminalOutput
                            }
                        } else {
                            terminalOutput
                        }
                    }

                    Button {
                        checkQuota()
                    } label: {
                        if isChecking { CircularArcSpinner(size: 16) }
                        else { Label("Check Quota", systemImage: "arrow.clockwise") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isChecking || isSending)

                    if (!isRunning || error != nil) && !(transcript.showsCodeEntry && !isRunning) {
                        Button("Restart Sign-in") { start() }
                            .disabled(isChecking)
                    }
                }
                .padding(20)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    Button { send(.up) } label: {
                        Label("Up", systemImage: "arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityIdentifier("agy-login-up")
                    Button { send(.down) } label: {
                        Label("Down", systemImage: "arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityIdentifier("agy-login-down")
                    Button { send(.confirm) } label: {
                        Label("Enter", systemImage: "return")
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityIdentifier("agy-login-enter")
                }
                .buttonStyle(.bordered)
                .disabled(!isRunning || isSending || !transcript.isChoosingLoginMethod)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.cardBackground)
                .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
            }
            .navigationTitle("Sign in to Agy")
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
                }
            }
            .background {
                AgySignInBrowser(url: browser?.url, onDone: { browser = nil })
                    .frame(width: 0, height: 0)
            }
            .onAppear { if loginTask == nil { start() } }
            .onDisappear {
                sessionID = UUID()
                loginTask?.cancel()
                inputTask?.cancel()
                checkTask?.cancel()
                code = ""
                transcript = AgySignInTranscript()
            }
        }
    }

    private var terminalOutput: some View {
        Text(String(transcript.displayText.suffix(6000)))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.cardBackground, in: RoundedRectangle.continuous(DesignSystem.CornerRadius.xl))
    }

    private var codeSubmissionStatus: String {
        if !isRunning {
            return "The SSH sign-in session has ended. Restart sign-in and get a new authorization code."
        }
        if isSending || !transcript.awaitingCode { return "Waiting for Agy to accept the code…" }
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No code entered yet. Copy the code from the sign-in page, then tap Paste."
        }
        return "Code is ready to submit."
    }

    private func start() {
        let previous = loginTask
        previous?.cancel()
        inputTask?.cancel()
        checkTask?.cancel()
        let id = UUID()
        sessionID = id
        transcript = AgySignInTranscript(waitsForReadyMarker: true)
        code = ""
        error = nil
        isRunning = true
        isSending = false
        isChecking = false
        loginTask = Task {
            await previous?.value
            guard !Task.isCancelled, sessionID == id else { return }
            do {
                try await appModel.connection.runAgyLogin(id: id) { output in
                    await MainActor.run {
                        guard sessionID == id, !Task.isCancelled else { return }
                        transcript.append(output)
                    }
                }
                guard sessionID == id, !Task.isCancelled else { return }
                error = "The Agy session ended. Check quota if you finished signing in, or restart sign-in."
            } catch is CancellationError {
                // Closing this sheet ends only its PTY.
            } catch {
                guard sessionID == id, !Task.isCancelled else { return }
                self.error = "Sign-in ended. You can check quota or restart sign-in."
            }
            if sessionID == id { isRunning = false }
        }
    }

    private func send(_ input: AgySignInInput) {
        guard !isSending else { return }
        isSending = true
        error = nil
        let id = sessionID
        if case .code = input {
            code = ""
            // Suppress subsequent terminal echoes of the credential in the UI.
            transcript.markCodeSubmitted()
        }
        inputTask = Task {
            defer { if sessionID == id { isSending = false } }
            do {
                try await appModel.connection.sendAgyLoginInput(input, id: id)
                guard !Task.isCancelled, sessionID == id else { return }
                if case .code = input { checkQuota(delay: true) }
            } catch {
                guard !Task.isCancelled, sessionID == id else { return }
                self.error = "Could not send to Agy. Restart sign-in and try again."
            }
        }
    }

    private func checkQuota(delay: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        error = nil
        let id = sessionID
        checkTask = Task {
            defer { if sessionID == id { isChecking = false } }
            do {
                if delay { try await Task.sleep(for: .seconds(3)) }
                let report = try await appModel.connection.quotaReport()
                try Task.checkCancellation()
                guard sessionID == id else { return }
                let agy = report.providers.first { $0.provider == "agy" || $0.provider == "antigravity" }
                guard let agy, agy.state?.status == "fresh", agy.state?.stale != true,
                      agy.windows.contains(where: { $0.percentRemaining != nil }) else {
                    error = "Agy is not reporting fresh quota yet. Finish signing in, then check again."
                    return
                }
                await model.refreshUsage(appModel.connection, force: true)
                try Task.checkCancellation()
                loginTask?.cancel()
                dismiss()
            } catch is CancellationError {
            } catch {
                guard sessionID == id, !Task.isCancelled else { return }
                self.error = "Could not check quota. Try again when connected."
            }
        }
    }
}

private struct SignInBrowserLink: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AgySignInBrowser: UIViewControllerRepresentable {
    let url: URL?
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> Presenter {
        Presenter()
    }

    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.url = url
        controller.onDone = onDone
        controller.presentBrowserIfNeeded()
    }

    /// Present Safari modally, as required by SafariServices, rather than
    /// embedding it as a child of a SwiftUI sheet's hosting controller.
    final class Presenter: UIViewController, SFSafariViewControllerDelegate {
        var url: URL?
        var onDone: (() -> Void)?
        private var browser: SFSafariViewController?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            presentBrowserIfNeeded()
        }

        func presentBrowserIfNeeded() {
            guard let url, viewIfLoaded?.window != nil, browser == nil else { return }
            let controller = SFSafariViewController(url: url)
            controller.delegate = self
            controller.modalPresentationStyle = .overFullScreen
            browser = controller
            present(controller, animated: true)
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone?()
            controller.dismiss(animated: true) { [weak self] in
                self?.browser = nil
            }
        }
    }
}

import SwiftUI
import WebKit

struct TerminalBrowserLink: Identifiable {
    let id = UUID()
    let url: URL
}

enum TerminalBrowserPolicy {
    static func isWeb(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
    }

    static func isGitHub(_ url: URL) -> Bool {
        isWeb(url) && ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
    }
}

/// A focused browser for terminal links. App handoff always requires a toolbar tap.
struct TerminalBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser: TerminalBrowserModel
    @State private var handoffFailed = false

    init(url: URL) {
        _browser = StateObject(wrappedValue: TerminalBrowserModel(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if browser.isLoading { ProgressView().frame(maxWidth: .infinity).padding(4) }
                if let error = browser.error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding(8)
                }
                TerminalBrowserWebView(browser: browser)
                    .accessibilityIdentifier("terminal-browser-webview")
            }
            .navigationTitle(browser.url.host ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("terminal-browser-done")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack).accessibilityLabel("Back")
                    Button { browser.webView.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward).accessibilityLabel("Forward")
                    Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                    Spacer()
                    if TerminalBrowserPolicy.isGitHub(browser.url) {
                        Button("Open in GitHub") {
                            UIApplication.shared.open(browser.url, options: [.universalLinksOnly: true]) { opened in
                                if !opened { handoffFailed = true }
                            }
                        }
                        .accessibilityIdentifier("terminal-browser-open-github")
                    }
                    Button {
                        UIApplication.shared.open(browser.url) { opened in
                            if !opened { handoffFailed = true }
                        }
                    } label: { Image(systemName: "safari") }
                    .accessibilityLabel("Open in Browser")
                }
            }
            .alert("Couldn’t open this link", isPresented: $handoffFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The app may not be installed or may not support this page. You can keep browsing here or use Open in Browser.")
            }
        }
    }
}

@MainActor
final class TerminalBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let webView = WKWebView()
    @Published private(set) var url: URL
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var error: String?
    private var observations: [NSKeyValueObservation] = []

    init(url: URL) {
        self.url = url
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() }
        ]
        if TerminalBrowserPolicy.isWeb(url) { webView.load(URLRequest(url: url)) }
    }

    private nonisolated func scheduleUpdate() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            url = webView.url ?? url
            isLoading = webView.isLoading
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
        }
    }

    func reload() {
        error = nil
        if webView.url == nil { webView.load(URLRequest(url: url)) }
        else { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, TerminalBrowserPolicy.isWeb(url) else {
            decisionHandler(.cancel)
            return
        }
        // Load tapped links ourselves so universal links and new-window links
        // stay in the drawer until the reader chooses an external toolbar action.
        if navigationAction.targetFrame == nil || navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        error = nil
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.error = error.localizedDescription }
    }
}

private struct TerminalBrowserWebView: UIViewRepresentable {
    let browser: TerminalBrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

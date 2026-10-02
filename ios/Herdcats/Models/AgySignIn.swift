import Foundation

/// The sign-in sheet is a text terminal, so advertise only basic VT capabilities.
/// Agy waits for DA2 before drawing its SSH login UI. Consume requests once,
/// including requests split across SSH packets; never interpret OSC/APC payloads.
struct AgyTerminalResponder: Sendable {
    private enum State: Sendable {
        case text, escape, csi(String), controlString, stringEscape
    }
    private var state: State = .text

    mutating func responses(to text: String) -> String {
        var replies = ""
        for scalar in text.unicodeScalars {
            switch state {
            case .text:
                if scalar.value == 27 { state = .escape }
            case .escape:
                switch scalar {
                case "[": state = .csi("")
                case "]", "_", "P", "^", "X": state = .controlString
                default: state = .text
                }
            case .csi(let parameters):
                if (0x40...0x7e).contains(scalar.value) {
                    if scalar == "c" {
                        if parameters == ">" || parameters == ">0" {
                            replies += "\u{1B}[>0;0;0c"
                        } else if parameters.isEmpty || parameters == "0" {
                            replies += "\u{1B}[?1;0c"
                        }
                    }
                    state = .text
                } else if scalar.value == 27 {
                    state = .escape
                } else if parameters.count < 64 {
                    state = .csi(parameters + String(scalar))
                } else {
                    state = .text
                }
            case .controlString:
                if scalar.value == 7 { state = .text }
                else if scalar.value == 27 { state = .stringEscape }
            case .stringEscape:
                state = scalar == "\\" || scalar.value == 7 ? .text : .controlString
            }
        }
        return replies
    }
}

/// Bounded, ephemeral terminal text. Never persisted or logged.
struct AgySignInTranscript: Sendable {
    static let readyMarker = "HERDRCAT_AGY_LOGIN_READY"
    private var raw = ""
    private var waitsForReadyMarker: Bool
    private(set) var codeSubmitted = false

    init(waitsForReadyMarker: Bool = false) {
        self.waitsForReadyMarker = waitsForReadyMarker
    }

    mutating func append(_ text: String) {
        guard !codeSubmitted else { return }
        raw = String((raw + text).suffix(65_536))
        if waitsForReadyMarker, let marker = raw.range(of: Self.readyMarker) {
            raw = String(raw[marker.upperBound...])
            waitsForReadyMarker = false
        }
    }

    mutating func markCodeSubmitted() {
        codeSubmitted = true
        raw = ""
    }

    var plainText: String {
        guard !waitsForReadyMarker else { return "" }
        return raw.replacingOccurrences(of: "\u{1B}[\\]_^PX][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
    }

    var displayText: String {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var awaitingCode: Bool {
        guard !codeSubmitted else { return false }
        let text = plainText.lowercased()
        return text.contains("enter the authorization code")
            || text.contains("paste the authorization code")
            || (text.contains("copy the code displayed in the browser") && text.contains("paste it below"))
    }

    var isChoosingLoginMethod: Bool {
        guard !codeSubmitted, !awaitingCode, authorizationURL == nil else { return false }
        let text = plainText.lowercased()
        return text.contains("select login method") || text.contains("other sign-in options")
            || text.contains("sign in with") || text.contains("continue with google")
    }

    /// Keep code entry visible while the CLI is still printing its prompt.
    /// Submission still requires the explicit prompt before writing to the PTY.
    var showsCodeEntry: Bool {
        !codeSubmitted && (awaitingCode || authorizationURL != nil)
    }

    var authorizationURL: URL? {
        // Require a delimiter so a URL split across SSH packets is not opened prematurely.
        let text = plainText
        guard let pattern = try? NSRegularExpression(pattern: #"https://[^\s<>\"'\x00-\x1F]+(?=\s|[<>\"'])"#) else { return nil }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])),
                  Self.isAuthorizationURL(url) else { return nil }
            return url
        }.last
    }

    static func isAuthorizationURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(),
              ["accounts.google.com", "antigravity.google", "www.antigravity.google", "antigravity.google.com"].contains(host)
        else { return false }
        return url.path.lowercased().contains("auth")
    }
}

enum AgySignInInput: Sendable {
    case up, down, confirm, code(String)

    func terminalText(awaitingCode: Bool) throws -> String {
        switch self {
        case .code(let raw):
            let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard awaitingCode, !code.isEmpty, code.utf8.count <= 8192,
                  code.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
                throw HerdrError.invalidConfiguration("Paste the authorization code while Agy is waiting for it.")
            }
            // Written directly to the PTY, never evaluated by a shell.
            return code + "\r"
        case .up, .down, .confirm:
            guard !awaitingCode else {
                throw HerdrError.invalidConfiguration("Agy is waiting for an authorization code.")
            }
            switch self {
            case .up: return "\u{1B}[A"
            case .down: return "\u{1B}[B"
            default: return "\r"
            }
        }
    }
}

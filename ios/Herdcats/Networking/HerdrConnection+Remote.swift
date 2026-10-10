import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

extension HerdrConnection {
    // MARK: - Remote command plumbing

    /// Marker echoed when no herdr binary could be located on the remote host.
    static let notFoundMarker = "HERDRCAT_HERDR_NOT_FOUND"
    /// Marker echoed when no quota-axi binary could be located on the remote host.
    static let quotaAxiNotFoundMarker = "HERDRCAT_QUOTA_AXI_NOT_FOUND"
    static let exitMarkerPrefix = "HERDRCAT_EXIT_"

    /// Builds the POSIX shell wrapper. The inner script deliberately avoids
    /// single quotes because it is embedded in `sh -c '...'`.
    static func remoteCommand(_ args: String) -> String {
        let script = """
        B=$(command -v herdr 2>/dev/null)
        if [ -z "$B" ]; then
          for P in "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
            if [ -x "$P" ]; then B="$P"; break; fi
          done
        fi
        if [ -z "$B" ]; then echo \(notFoundMarker); exit 0; fi
        O=$("$B" \(args) 2>&1)
        R=$?
        if [ "$R" -ne 0 ]; then echo "\(exitMarkerPrefix)$R"; fi
        echo "$O"
        """
        return "exec sh -c '\(script)'"
    }

    /// Prefix of the line that reports the remote `quota-axi` version.
    static let quotaAxiVersionPrefix = "HERDRCAT_QUOTA_AXI_VERSION="

    /// Adds common install locations and the login shell's PATH, so tools
    /// installed for interactive shells resolve over a non-login SSH exec.
    static var loginPathSetup: String {
        let additionalPaths = "$HOME/.local/bin:$HOME/.local/share/mise/shims:"
            + "/opt/homebrew/bin:/usr/local/bin:$HOME/.bun/bin:"
            + "$HOME/.antigravity/antigravity/bin:$HOME/.antigravity-ide/antigravity-ide/bin:"
        return """
        export PATH="\(additionalPaths)$PATH"
        LP=$([ -x "$SHELL" ] && "$SHELL" -lc 'printf "\\nHERDRCAT_PATH=%s\\n" "$PATH"' 2>/dev/null |
          sed -n 's/^HERDRCAT_PATH=//p' | tail -1)
        case "$LP" in
          /*) export PATH="$PATH:$LP" ;;
        esac
        """
    }

    /// Shell body for the remote quota-axi probe (no outer `sh -c` wrapper).
    static var quotaAxiRemoteScript: String {
        quotaAxiRemoteScript(provider: nil)
    }

    /// Same probe scoped to one provider when `provider` is set (card retry).
    static func quotaAxiRemoteScript(provider: String?) -> String {
        let scope = provider.map { " --provider \(shellSafeArgument($0))" } ?? ""
        return """
        \(loginPathSetup)
        B=$(command -v quota-axi 2>/dev/null)
        if [ -z "$B" ]; then
          for P in "$HOME/.local/bin/quota-axi" "$HOME/.local/share/mise/shims/quota-axi" \\
            /opt/homebrew/bin/quota-axi /usr/local/bin/quota-axi; do
            if [ -x "$P" ] || [ -L "$P" ]; then B="$P"; break; fi
          done
        fi
        if [ -z "$B" ]; then
          echo \(quotaAxiNotFoundMarker)
          exit 0
        fi
        echo "\(quotaAxiVersionPrefix)$("$B" --version 2>/dev/null | tr -d '\\r\\n')"
        O=$("$B"\(scope) --json --no-credential-refresh 2>/dev/null)
        R=$?
        if [ "$R" -ne 0 ]; then
          echo "\(exitMarkerPrefix)$R"
          echo "$O"
          exit 0
        fi
        echo "$O"
        exit 0
        """
    }

    /// Locates `quota-axi`, then runs a read-only JSON snapshot for all providers.
    ///
    /// Non-interactive SSH has a bare PATH, so we prepend `~/.local/bin` (for the
    /// Antigravity agy CLI) and mise / Homebrew locations before resolving.
    /// The script is passed via `shellSafeArgument` so it cannot break `sh -c`
    /// quoting, and it always exits 0 so Citadel does not surface raw exit codes.
    static func quotaAxiRemoteCommand(provider: String? = nil) -> String {
        "exec /bin/sh -c \(shellSafeArgument(quotaAxiRemoteScript(provider: provider)))"
    }

    func runQuotaAxi(timeout: TimeInterval, provider: String? = nil) async throws -> QuotaAxiOutput {
        guard let client else { throw HerdrError.notConnected }
        let owned = generation
        let command = Self.quotaAxiRemoteCommand(provider: provider)
        print("[HC] exec: quota-axi --json")
        do {
            let buffer = try await withTimeout(
                seconds: timeout,
                label: "quota-axi",
                onTimeout: { [weak self] in
                    await self?.timeoutTeardown(expected: owned)
                },
                operation: { try await client.executeCommand(command, maxResponseSize: 2 * 1024 * 1024) }
            )
            guard generation == owned else { throw HerdrError.notConnected }
            return try Self.interpretQuotaAxiOutput(String(buffer: buffer))
        } catch let error as HerdrError {
            throw error
        } catch {
            // Citadel surfaces non-zero exits as commandFailed — map to a typed error.
            let description = String(describing: error)
            if description.localizedCaseInsensitiveContains("commandfailed")
                || description.localizedCaseInsensitiveContains("exitcode") {
                throw HerdrError.unexpectedResponse(
                    "quota-axi failed on the Mac (exit \(description)). Is it installed and on PATH?"
                )
            }
            throw error
        }
    }

    /// quota-axi wrapper output: the reported CLI version plus its JSON payload.
    struct QuotaAxiOutput: Equatable, Sendable {
        var version: String?
        var json: String
    }

    /// Interprets quota-axi wrapper output (markers + raw JSON, no herdr envelope).
    static func interpretQuotaAxi(_ raw: String) throws -> String {
        try interpretQuotaAxiOutput(raw).json
    }

    /// Same as `interpretQuotaAxi`, keeping the version line the wrapper emits so
    /// the UI can say which CLI produced a report that is missing a provider.
    static func interpretQuotaAxiOutput(_ raw: String) throws -> QuotaAxiOutput {
        var version: String?
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        if let index = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(quotaAxiVersionPrefix)
        }) {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            let value = String(line.dropFirst(quotaAxiVersionPrefix.count))
                .trimmingCharacters(in: .whitespaces)
            version = value.isEmpty ? nil : value
            lines.remove(at: index)
        }
        let json = try interpretQuotaAxiJSON(lines.joined(separator: "\n"))
        return QuotaAxiOutput(version: version, json: json)
    }

    static func interpretQuotaAxiJSON(_ raw: String) throws -> String {
        let output = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if output == quotaAxiNotFoundMarker {
            throw HerdrError.quotaAxiNotFound
        }
        if output.hasPrefix(exitMarkerPrefix) {
            let firstLine = output.prefix { $0 != "\n" }
            let rest = String(output.dropFirst(firstLine.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = Int(firstLine.dropFirst(exitMarkerPrefix.count)) ?? -1
            // quota-axi sometimes still prints JSON before failing a provider.
            if let brace = rest.firstIndex(of: "{") {
                return String(rest[brace...])
            }
            if !rest.isEmpty {
                throw HerdrError.unexpectedResponse("quota-axi exited \(code): \(rest)")
            }
            throw HerdrError.unexpectedResponse("quota-axi exited \(code)")
        }
        if output.isEmpty {
            throw HerdrError.unexpectedResponse("quota-axi returned empty output")
        }
        // Some shells echo markers before JSON; keep from the first `{`.
        if let brace = output.firstIndex(of: "{") {
            return String(output[brace...])
        }
        return output
    }

    /// Wraps an arbitrary string as a single shell argument that is safe to
    /// embed in the remote `sh -c '...'` wrapper: the bytes are octal-escaped
    /// for `printf`, so quotes, dollar signs, backticks, and newlines in user
    /// input never reach shell parsing. The result contains no single quotes
    /// (which would break the outer quoting) and no unescaped double quotes.
    static func shellSafeArgument(_ string: String) -> String {
        "\"$(printf \"\(printfOctal(string))\")\""
    }

    static func printfOctal(_ string: String) -> String {
        string.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    }

    /// Runs an arbitrary remote shell script (not routed through `herdr`).
    func runRemoteShell(
        _ script: String,
        timeout: TimeInterval = 20,
        owned expectedGeneration: ConnectionGeneration? = nil
    ) async throws -> String {
        let owned = expectedGeneration ?? generation
        try requireGeneration(owned)
        try requireHostServices()
        guard let client else { throw HerdrError.notConnected }
        let command = "exec /bin/sh -c \(Self.shellSafeArgument(script))"
        let buffer = try await withTimeout(
            seconds: timeout,
            label: "remote shell",
            onTimeout: { [weak self] in
                await self?.timeoutTeardown(expected: owned)
            },
            operation: { try await client.executeCommand(command, maxResponseSize: 1024 * 1024) }
        )
        guard generation == owned else { throw HerdrError.notConnected }
        return String(buffer: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveAttachmentDirectory(owned: ConnectionGeneration) async throws -> String {
        try requireGeneration(owned)
        let home = try await runRemoteShell(#"cd "$HOME" && pwd -P"#, owned: owned)
        try requireGeneration(owned)
        guard home.hasPrefix("/"), !home.contains("\n"), !home.contains("\0") else {
            throw HerdrError.unexpectedResponse("could not resolve remote HOME")
        }
        return "\(home)/.cache/herdrcat/attachments"
    }

    func prepareAttachmentDirectory(_ directory: String, owned: ConnectionGeneration) async throws {
        try requireGeneration(owned)
        _ = try await runRemoteShell(Self.attachmentDirectoryPreparationScript(directory: directory), owned: owned)
        try requireGeneration(owned)
    }

    /// Creates the private cache path one component at a time and fails closed
    /// if any component is a symlink (including a dangling symlink).
    static func attachmentDirectoryPreparationScript(directory: String) -> String {
        let dirOctal = printfOctal(directory)
        return """
        set -eu
        DIR=$(printf "\(dirOctal)")
        ATTACHMENTS="$DIR"
        HERDRCAT=$(dirname "$ATTACHMENTS")
        CACHE=$(dirname "$HERDRCAT")
        umask 077
        for PATH_PART in "$CACHE" "$HERDRCAT" "$ATTACHMENTS"; do
          if [ -L "$PATH_PART" ]; then
            echo "attachment storage path contains a symlink" >&2
            exit 1
          fi
        done
        if [ ! -d "$CACHE" ]; then mkdir -m 700 "$CACHE"; fi
        if [ -L "$CACHE" ] || [ ! -d "$CACHE" ]; then exit 1; fi
        if [ ! -d "$HERDRCAT" ]; then mkdir -m 700 "$HERDRCAT"; fi
        if [ -L "$HERDRCAT" ] || [ ! -d "$HERDRCAT" ]; then exit 1; fi
        chmod 700 "$HERDRCAT"
        if [ ! -d "$ATTACHMENTS" ]; then mkdir -m 700 "$ATTACHMENTS"; fi
        if [ -L "$ATTACHMENTS" ] || [ ! -d "$ATTACHMENTS" ]; then exit 1; fi
        chmod 700 "$ATTACHMENTS"
        """
    }

    static func sanitizedAttachmentExtension(_ raw: String) -> String {
        let cleaned = raw.lowercased().filter(\.isLetter)
        switch cleaned {
        case "jpg", "jpeg": return "jpg"
        case "png": return "png"
        case "webp": return "webp"
        default: return "jpg"
        }
    }

    /// Builds the pane prompt that asks an agent to open an uploaded image.
    static func imagePrompt(remotePath: String, userMessage: String) -> String {
        let header = "Please open and inspect this image: \(remotePath)"
        let trimmed = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return header }
        return "\(header)\n\n\(trimmed)"
    }

    /// Interprets wrapper output: strips markers, maps failures to typed errors,
    /// while preserving leading indentation and blank lines in payload output.
    static func interpret(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == notFoundMarker {
            throw HerdrError.herdrNotFound
        }
        if raw.hasPrefix(exitMarkerPrefix) || trimmed.hasPrefix(exitMarkerPrefix) {
            let normalized = raw.hasPrefix(exitMarkerPrefix) ? raw : trimmed
            let firstLine = normalized.prefix { $0 != "\n" }
            let rest = String(normalized.dropFirst(firstLine.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code = Int(firstLine.dropFirst(exitMarkerPrefix.count)) ?? -1
            if let data = rest.data(using: .utf8),
               let envelope = try? JSONDecoder().decode(HerdrEnvelope<WorkspaceListResult>.self, from: data),
               let apiError = envelope.error {
                throw HerdrError.api(code: apiError.code, message: apiError.message)
            }
            throw HerdrError.herdrExit(code)
        }
        if trimmed.isEmpty {
            throw HerdrError.unexpectedResponse("empty output")
        }
        var output = raw
        while output.hasSuffix("\n") || output.hasSuffix("\r") {
            output.removeLast()
        }
        return output
    }

    /// Decodes a herdr JSON envelope, promoting API errors to typed errors.
    static func decode<Result: Decodable>(_ output: String, as resultType: Result.Type) throws -> Result {
        guard let data = output.data(using: .utf8) else {
            throw HerdrError.unexpectedResponse("output was not valid UTF-8")
        }
        let decoder = JSONDecoder()
        do {
            let envelope = try decoder.decode(HerdrEnvelope<Result>.self, from: data)
            if let apiError = envelope.error {
                throw HerdrError.api(code: apiError.code, message: apiError.message)
            }
            guard let result = envelope.result else {
                throw HerdrError.unexpectedResponse("missing result payload")
            }
            return result
        } catch let error as HerdrError {
            throw error
        } catch {
            if let envelope = try? decoder.decode(HerdrEnvelope<WorkspaceListResult>.self, from: data),
               let apiError = envelope.error {
                throw HerdrError.api(code: apiError.code, message: apiError.message)
            }
            throw HerdrError.unexpectedResponse(String(describing: error))
        }
    }
}

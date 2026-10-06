import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH

extension HerdrConnection: PaneLiveInputSending {}

// MARK: - Friendly error mapping

extension HerdrConnection {
    /// Whether an error message indicates the client is disconnected or attempting to connect.
    static func isDisconnectionOrTransitionMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("Not connected")
            || message.localizedCaseInsensitiveContains("Connecting to")
    }

    /// Maps low-level SSH transport errors to human-readable guidance.
    static func friendlyMessage(for error: Error, config: ConnectionConfig? = nil) -> String {
        if error is CancellationError { return "Connection interrupted. Retrying…" }
        if let error = error as? SSHHostKeyError { return error.localizedDescription }
        if let error = error as? SSHHostKeyStore.StoreError { return error.localizedDescription }
        if let keyError = error as? OpenSSHKeyError {
            return keyError.errorDescription ?? keyError.localizedDescription
        }
        if let herdrError = error as? HerdrError { return friendlyHerdrMessage(herdrError) }
        return friendlyTransportMessage(for: error, config: config)
    }

    private static func friendlyHerdrMessage(_ error: HerdrError) -> String {
        switch error {
        case let .api(code, message):
            return friendlyAPIMessage(code: code, message: message, fallback: error)
        case let .unexpectedResponse(detail):
            if detail.localizedCaseInsensitiveContains("quota-axi returned empty output") {
                return "quota-axi returned no data. Pull to refresh."
            }
            if detail.localizedCaseInsensitiveContains("quota-axi") { return detail }
            return error.errorDescription ?? detail
        default:
            return error.errorDescription ?? String(describing: error)
        }
    }

    private static func friendlyAPIMessage(code: String, message: String, fallback: HerdrError) -> String {
        switch code {
        case "agent_blocked":
            return "The agent is waiting for a decision on the remote machine (approval/question). "
                + "Resolve it there, then send again."
        case "agent_prompt_stalled":
            return "The agent did not accept the message. Check the pane on the remote machine and try again."
        case "agent_not_ready", "agent_not_found":
            return "No ready agent in this pane — open or start one on the remote machine, then send again."
        case "not_git_worktree":
            return "This workspace is not inside a Git worktree. Open a Git repository to use worktrees."
        case "worktree_create_failed":
            return "Failed to create worktree: \(message)"
        case "worktree_open_failed":
            return "Failed to open worktree: \(message)"
        case "worktree_remove_failed":
            return "Failed to remove worktree: \(message)"
        default:
            return fallback.errorDescription ?? message
        }
    }

    private static func friendlyTransportMessage(for error: Error, config: ConnectionConfig?) -> String {
        let description = String(describing: error)
        if description.contains("connectTimeout") {
            return "Timed out reaching the host — check the IP address and that SSH "
                + "(Remote Login) is enabled on the machine."
        }
        if description.contains("Connection refused")
            || description.contains("connectFailed")
            || description.contains("ECONNREFUSED") {
            return "Connection refused — nothing is listening on that port. "
                + "Is SSH enabled and the port correct?"
        }
        if description.lowercased().contains("authentication")
            || description.contains("allAuthenticationOptionsFailed") {
            return authenticationFailureMessage(config: config)
        }
        if description.contains("Machine is not") || description.contains("unreachable") {
            return "The host could not be reached. Check the IP address and network."
        }
        if let agentMessage = friendlyLegacyAgentMessage(description) { return agentMessage }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return description
    }

    private static func authenticationFailureMessage(config: ConnectionConfig?) -> String {
        if let config, case let .privateKey(pem, _) = config.auth {
            if let pubKey = try? OpenSSHEd25519.parseOpenSSHPublicKeyString(pem: pem) {
                return "Authentication failed for user '\(config.username)' at \(config.host). "
                    + "Verify that the user exists and this public key is in ~/.ssh/authorized_keys: \(pubKey)"
            }
            return "Authentication failed for user '\(config.username)' at \(config.host). "
                + "Verify the username and ensure the matching public key is in ~/.ssh/authorized_keys on the host."
        } else if let config {
            return "Authentication failed for user '\(config.username)' at \(config.host) — "
                + "check the username and password."
        }
        return "Authentication failed — check the username and password/key."
    }

    private static func friendlyLegacyAgentMessage(_ description: String) -> String? {
        if description.contains("agent_blocked") {
            return "The agent is waiting for a decision on your Mac (approval/question). "
                + "Resolve it there, then send again."
        }
        if description.contains("agent_prompt_stalled") {
            return "The agent did not accept the message. Check the pane on your Mac and try again."
        }
        if description.contains("agent_not_ready") || description.contains("agent_not_found") {
            return "No ready agent in this pane — open or start one on your Mac, then send again."
        }
        return nil
    }
}

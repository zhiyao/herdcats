import Foundation

/// One-shot Live toolbar modifier / chord composer for ordered Live delivery.
///
/// Arms Control, Alt, and Shift for the next base key and emits Herdr
/// `pane send-keys` tokens such as `ctrl+alt+shift+tab`. Command/Meta fails closed: disposable-pane probes showed
/// Herdr accepts `cmd+…` / `super+…` / `command+…` but encodes kitty Super
/// CSI-u sequences (e.g. `^[[99;9u`), which shells and agent TUIs do not treat
/// as macOS ⌘ — so no Command token is invented or sent.
struct PaneLiveModifierComposer: Equatable, Sendable {
    enum Modifier: String, Sendable, Equatable, CaseIterable {
        case control
        case alt
        case shift
        case command
    }

    enum Outcome: Sendable, Equatable {
        /// Armed modifier changed; no remote write.
        case state(armed: Set<Modifier>)
        /// Enqueue on `PaneLiveInputQueue` (preserves call order).
        case enqueue(PaneLiveInputEvent)
        /// Command mapping unavailable; nothing enqueued and no token invented.
        case unsupportedCommand
    }

    enum OrderedKeysError: Error, Sendable, Equatable {
        case unsupportedCommandMapping
        case emptyToken
    }

    /// Verified Herdr Control prefix (`ctrl+c` interrupts a disposable shell).
    static let controlToken = "ctrl"

    /// Command has no verified agent-TUI mapping — always `false`.
    static var isCommandMappingSupported: Bool { false }

    private(set) var armed: Set<Modifier> = []
    private var sessionPaneId: String?
    private var sessionGeneration: ConnectionGeneration?

    /// Clears any armed modifier without sending keys.
    mutating func reset() {
        armed = []
    }

    /// Clears armed state when the Live session identity changes (pane switch,
    /// disconnect, or SSH generation bump). Repeating the same session is a no-op.
    mutating func noteSession(_ session: PaneLiveInputSession?) {
        let pane = session?.paneId
        let generation = session?.generation
        if pane != sessionPaneId || generation != sessionGeneration {
            armed = []
            sessionPaneId = pane
            sessionGeneration = generation
        }
    }

    /// Toggles one modifier without clearing the others. Command fails closed.
    mutating func toggle(_ modifier: Modifier) -> Outcome {
        guard modifier != .command else { return .unsupportedCommand }
        if armed.contains(modifier) {
            armed.remove(modifier)
        } else {
            armed.insert(modifier)
        }
        return .state(armed: armed)
    }

    /// Applies a base Herdr key token (`c`, `esc`, `tab`, `up`, …).
    /// With modifiers armed, emits one combined chord and disarms.
    mutating func applyBaseKey(_ token: String) -> Outcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .state(armed: armed)
        }
        return apply(.keys([trimmed]))
    }

    /// Applies a Live keyboard / accessory event.
    ///
    /// - Unsupported Command/Meta/Super tokens fail closed on every path
    ///   (armed or not; any index in a multi-key array).
    /// - One-shot modifiers wrap only the first key, or a single printable
    ///   ASCII text scalar, then disarm.
    /// - Multi-character text/paste, emoji, or non-ASCII while armed:
    ///   disarm and forward the committed text unchanged so a later key cannot
    ///   inherit a stale Ctrl arm.
    mutating func apply(_ event: PaneLiveInputEvent) -> Outcome {
        if case let .keys(keys) = event,
           keys.contains(where: { Self.usesUnsupportedCommandMapping($0) }) {
            armed = []
            return .unsupportedCommand
        }

        guard !armed.isEmpty else {
            return .enqueue(event)
        }
        return applyModifiers(to: event)
    }

    /// Builds an ordered multi-token `.keys` event. Rejects Command/Meta/Super
    /// mappings rather than inventing or forwarding an unverified ⌘ token.
    static func orderedKeysEvent(
        _ tokens: [String]
    ) -> Result<PaneLiveInputEvent, OrderedKeysError> {
        var normalized: [String] = []
        normalized.reserveCapacity(tokens.count)
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure(.emptyToken)
            }
            if Self.usesUnsupportedCommandMapping(trimmed) {
                return .failure(.unsupportedCommandMapping)
            }
            normalized.append(trimmed)
        }
        guard !normalized.isEmpty else {
            return .failure(.emptyToken)
        }
        return .success(.keys(normalized))
    }

    // MARK: - Private

    private mutating func applyModifiers(to event: PaneLiveInputEvent) -> Outcome {
        switch event {
        case let .keys(keys):
            guard let first = keys.first,
                  !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                // Empty key list is not a chord trigger; leave arm unchanged.
                return .enqueue(event)
            }
            // Unsupported Command tokens already rejected in `apply`.
            let modifiers = armed
            armed = []
            var composed = keys
            composed[0] = Self.chord(for: first, modifiers: modifiers)
            return .enqueue(.keys(composed))

        case let .text(text):
            // Herdr accepts printable single-character keys. Name space and
            // plus explicitly because trimming and '+' chord splitting would
            // otherwise erase their meaning. Committed Unicode and paste
            // continue through the text path unchanged.
            if let key = Self.keyToken(forCommittedText: text) {
                let modifiers = armed
                armed = []
                return .enqueue(.keys([Self.chord(for: key, modifiers: modifiers)]))
            }

            // Multi-character paste, emoji, or non-ASCII: disarm and forward
            // unchanged so Ctrl cannot stick onto a later unrelated key.
            armed = []
            return .enqueue(event)
        }
    }

    /// Herdr's key parser accepts printable single characters as base keys.
    private static func keyToken(forCommittedText text: String) -> String? {
        guard text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first,
              (0x20...0x7E).contains(scalar.value)
        else {
            return nil
        }
        if text == " " { return "space" }
        if text == "+" { return "plus" }
        return text
    }

    private static func chord(for base: String, modifiers: Set<Modifier>) -> String {
        let parts = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return base }
        let existing = Set(parts.dropLast().map { part in
            switch part {
            case "control": return "ctrl"
            case "option": return "alt"
            default: return part
            }
        })
        let prefixes: [(Modifier, String)] = [(.control, controlToken), (.alt, "alt"), (.shift, "shift")]
        let ordered = prefixes.compactMap { modifier, token in
            modifiers.contains(modifier) || existing.contains(token) ? token : nil
        }
        let other = parts.dropLast().filter { !["ctrl", "control", "alt", "option", "shift"].contains($0) }
        return (ordered + other + [key]).joined(separator: "+")
    }

    /// True when a token uses cmd / command / meta / super as a modifier prefix.
    /// Disposable-pane probes: these are CLI-accepted but encode kitty Super /
    /// Alt sequences unsuitable as verified macOS ⌘ for agent TUIs.
    static func usesUnsupportedCommandMapping(_ token: String) -> Bool {
        let parts = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count >= 2 else { return false }
        let unsupported: Set<String> = ["cmd", "command", "meta", "super"]
        // Modifier prefixes occupy every part except the final base key.
        return parts.dropLast().contains { unsupported.contains($0) }
    }
}

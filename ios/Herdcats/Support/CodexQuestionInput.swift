import Foundation

/// Where a blocked Codex pane accepts a typed free-text answer.
///
/// Herdr rejects `agent prompt` while an agent is blocked, but Codex question
/// menus still take typed text. Only the question layouts below match, so
/// approval menus (whose letters are hotkeys) never receive raw keystrokes.
enum CodexQuestionInput: Equatable {
    /// A notes or answer field has focus: type, then Enter submits.
    /// In the async question panel, typing also selects "Other".
    case answerField
    /// Question list with "None of the above" highlighted: Tab opens notes.
    case noneOfTheAboveSelected
    /// Async questions collapsed under the composer: ⌥↑ opens them.
    case collapsed

    /// Keys that move a non-field state toward `answerField`.
    var openingKeys: [String]? {
        switch self {
        case .answerField: nil
        case .noneOfTheAboveSelected: ["tab"]
        case .collapsed: ["alt+up"]
        }
    }

    /// Classifies a plain-text capture of the pane's visible screen.
    static func detect(_ screen: String) -> Self? {
        let lines = ANSIText.lines(from: screen)
            .map { $0.plain.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(24)
        if lines.contains(where: { $0.hasPrefix("Would you like to") }) { return nil }
        if lines.contains(where: { $0.contains("tab or esc to clear notes") && $0.contains("enter to submit answer") }) {
            return .answerField
        }
        if lines.contains(where: { $0.hasPrefix("enter submit") && $0.contains("main prompt") }) {
            return .answerField
        }
        if lines.contains(where: { $0.hasPrefix("tab to add notes") && $0.contains("enter to submit answer") }) {
            let highlighted = lines.contains { line in
                guard line.hasPrefix("› "), line.contains("None of the above") else { return false }
                return line.dropFirst(2).first?.isNumber == true
            }
            return highlighted ? .noneOfTheAboveSelected : nil
        }
        if lines.contains(where: { $0.hasSuffix("+ ↑ to answer") }),
           lines.contains(where: { $0.hasPrefix("? ") && $0.contains("question") }) {
            return .collapsed
        }
        return nil
    }

    /// Question fields are single-line; a typed newline could submit early.
    static func answerText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

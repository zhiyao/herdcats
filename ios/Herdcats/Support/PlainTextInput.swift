import UIKit

/// Turns off autocorrect, spell checking, and smart punctuation for every
/// text input in the app. Everything typed here is a host, key, shell command,
/// or agent prompt, where “smart” quotes, en dashes, and corrected words
/// break the input. SwiftUI's `.autocorrectionDisabled()` is not reliably
/// applied to vertical-axis `TextField`s (backed by `UITextView`) and has no
/// smart-punctuation counterpart, so this adjusts the UIKit views directly.
@MainActor
enum PlainTextInput {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: UITextField.textDidBeginEditingNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let field = note.object as? UITextField else { return }
                MainActor.assumeIsolated { apply(to: field) }
            },
            center.addObserver(
                forName: UITextView.textDidBeginEditingNotification,
                object: nil,
                queue: .main
            ) { note in
                guard let view = note.object as? UITextView else { return }
                MainActor.assumeIsolated { apply(to: view) }
            },
        ]
    }

    /// Reloads the keyboard only when a trait changed, since the keyboard
    /// was already configured by the time editing began.
    private static func apply(to input: some PlainTextConfigurable) {
        var changed = false
        if input.autocorrectionType != .no { input.autocorrectionType = .no; changed = true }
        if input.spellCheckingType != .no { input.spellCheckingType = .no; changed = true }
        if input.smartQuotesType != .no { input.smartQuotesType = .no; changed = true }
        if input.smartDashesType != .no { input.smartDashesType = .no; changed = true }
        if input.smartInsertDeleteType != .no { input.smartInsertDeleteType = .no; changed = true }
        if changed {
            input.reloadInputViews()
        }
    }
}

/// The concrete UIKit text inputs, whose traits are settable properties
/// rather than `UITextInputTraits`' optional requirements.
@MainActor
protocol PlainTextConfigurable: UIResponder {
    var autocorrectionType: UITextAutocorrectionType { get set }
    var spellCheckingType: UITextSpellCheckingType { get set }
    var smartQuotesType: UITextSmartQuotesType { get set }
    var smartDashesType: UITextSmartDashesType { get set }
    var smartInsertDeleteType: UITextSmartInsertDeleteType { get set }
}

extension UITextField: PlainTextConfigurable {}
extension UITextView: PlainTextConfigurable {}

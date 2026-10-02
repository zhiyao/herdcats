import Foundation
import UIKit

// MARK: - Haptic preference

/// User preference for tactile feedback across alerts and controls.
/// Persisted via `@AppStorage` / `UserDefaults` using `storageKey`.
enum HapticPreference {
    static let storageKey = "hapticsEnabled"
    static let `default`: Bool = true

    /// Reads the stored preference from `defaults`, falling back to `default`.
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: storageKey) == nil {
            return `default`
        }
        return defaults.bool(forKey: storageKey)
    }
}

// MARK: - Haptic feedback dispatcher

/// Centralized haptic feedback generator dispatching notifications and impacts
/// only when the user has enabled haptics in settings.
enum HapticFeedback {
    /// Plays an alert haptic corresponding to an agent status transition.
    ///
    /// - `.done`: Success notification feedback.
    /// - `.blocked`: Warning notification feedback.
    @MainActor
    static func play(for event: AgentAlertEvent, defaults: UserDefaults = .standard) {
        guard HapticPreference.isEnabled(defaults: defaults) else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        switch event {
        case .done:
            generator.notificationOccurred(.success)
        case .blocked:
            generator.notificationOccurred(.warning)
        }
    }

    /// Triggers an impact feedback with the given style.
    @MainActor
    static func impact(
        _ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium,
        defaults: UserDefaults = .standard
    ) {
        guard HapticPreference.isEnabled(defaults: defaults) else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    /// Triggers a selection changed feedback.
    @MainActor
    static func selection(defaults: UserDefaults = .standard) {
        guard HapticPreference.isEnabled(defaults: defaults) else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

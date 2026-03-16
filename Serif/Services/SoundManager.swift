import AppKit

@MainActor
enum SoundManager {
    enum Effect: String {
        /// Played when an email is successfully sent (after undo countdown).
        case sent = "Blow"
        /// Played on archive, delete, or other destructive email actions.
        case action = "Pop"
        /// Played when new mail arrives while the app is focused.
        case newMail = "Purr"
    }

    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKey.soundEffectsEnabled) as? Bool ?? true
    }

    static func play(_ effect: Effect) {
        guard isEnabled else { return }
        NSSound(named: effect.rawValue)?.play()
    }
}

import SwiftUI

@Observable
@MainActor
final class AppearanceManager {
    enum Preference: String, CaseIterable, Sendable {
        case system, light, dark
    }

    var preference: Preference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: UserDefaultsKey.appearancePreference)
        }
    }

    var colorScheme: ColorScheme? {
        switch preference {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: UserDefaultsKey.appearancePreference)
        if let stored, let pref = Preference(rawValue: stored) {
            self.preference = pref
        } else {
            // Migration: map old theme to appearance preference
            let oldThemeId = UserDefaults.standard.string(forKey: "selectedThemeId") ?? "midnight"
            let lightThemes = ["light", "paper", "violet", "mono", "ivory"]
            self.preference = lightThemes.contains(oldThemeId) ? .light : .dark
            UserDefaults.standard.removeObject(forKey: "selectedThemeId")
            UserDefaults.standard.removeObject(forKey: "themeOverrides")
            UserDefaults.standard.set(preference.rawValue, forKey: UserDefaultsKey.appearancePreference)
        }
    }
}

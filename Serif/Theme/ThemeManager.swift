import Observation
import SwiftUI

@Observable
@MainActor
final class ThemeManager {
    static let shared = ThemeManager()

    var currentTheme: Theme

    static let defaultThemes: [Theme] = [
        // Dark
        .midnight,
        .ocean,
        .serif,
        .nord,
        .rose,
        .solarizedDark,
        .dracula,
        .oneDark,
        .catppuccin,
        .tokyoNight,
        .forest,
        // Light
        .light,
        .paper,
        .violet,
        .mono,
        .ivory,
    ]

    var availableThemes: [Theme] = ThemeManager.defaultThemes

    /// The currently selected base theme ID.
    private(set) var selectedBaseID: String

    /// Custom color overrides per theme ID. Key: "themeID", Value: [colorKey: hexString].
    private var allOverrides: [String: [String: String]]

    private init() {
        let savedId = UserDefaults.standard.string(forKey: UserDefaultsKey.selectedThemeId) ?? "midnight"
        self.selectedBaseID = savedId

        // Load overrides
        let overrides: [String: [String: String]]
        if let data = UserDefaults.standard.data(forKey: UserDefaultsKey.themeOverrides),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
        self.allOverrides = overrides

        let base = Self.defaultThemes.first { $0.id == savedId } ?? .midnight
        let themeOverrides = overrides[savedId] ?? [:]
        self.currentTheme = themeOverrides.isEmpty ? base : base.applying(overrides: themeOverrides)
    }

    func selectTheme(_ theme: Theme) {
        selectedBaseID = theme.id
        UserDefaults.standard.set(theme.id, forKey: UserDefaultsKey.selectedThemeId)
        let overrides = allOverrides[theme.id] ?? [:]
        currentTheme = overrides.isEmpty ? theme : theme.applying(overrides: overrides)
    }

    // MARK: - Overrides

    var currentOverrides: [String: String] {
        allOverrides[selectedBaseID] ?? [:]
    }

    func setOverride(key: String, hex: String) {
        var overrides = allOverrides[selectedBaseID] ?? [:]
        overrides[key] = hex
        allOverrides[selectedBaseID] = overrides
        persistOverrides()
        let base = theme(byId: selectedBaseID)
        currentTheme = base.applying(overrides: overrides)
    }

    func removeOverride(key: String) {
        var overrides = allOverrides[selectedBaseID] ?? [:]
        overrides.removeValue(forKey: key)
        allOverrides[selectedBaseID] = overrides.isEmpty ? nil : overrides
        persistOverrides()
        let base = theme(byId: selectedBaseID)
        currentTheme = overrides.isEmpty ? base : base.applying(overrides: overrides)
    }

    func resetOverrides() {
        allOverrides[selectedBaseID] = nil
        persistOverrides()
        currentTheme = theme(byId: selectedBaseID)
    }

    var hasOverrides: Bool {
        !(allOverrides[selectedBaseID] ?? [:]).isEmpty
    }

    private func persistOverrides() {
        let data = try? JSONEncoder().encode(allOverrides)
        UserDefaults.standard.set(data, forKey: UserDefaultsKey.themeOverrides)
    }

    private func theme(byId id: String) -> Theme {
        availableThemes.first { $0.id == id } ?? .midnight
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var theme: Theme = .midnight
}

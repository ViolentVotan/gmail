import SwiftUI

struct SettingsView: View {
    var accountID: String = ""
    @Bindable var appearanceManager: AppearanceManager

    // Use the same @AppStorage keys as AppCoordinator and UndoActionManager
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("undoDuration") private var undoDuration = 5
    @AppStorage("refreshInterval") private var refreshInterval = 120
    @AppStorage("showDebugMenu") private var showDebugMenu = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestions = true

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalTab
            }

            Tab("Signatures", systemImage: "signature") {
                SignaturesSettingsView(accountID: accountID)
            }

            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") {
                FiltersSettingsView(accountID: accountID)
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                advancedTab
            }
        }
        .frame(width: 450, height: 320)
    }

    private var generalTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearanceManager.preference) {
                    Text("System").tag(AppearanceManager.Preference.system)
                    Text("Light").tag(AppearanceManager.Preference.light)
                    Text("Dark").tag(AppearanceManager.Preference.dark)
                }
                .pickerStyle(.segmented)
            }

            Section("Behavior") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)

                Picker("Undo duration", selection: $undoDuration) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }

                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                    Text("10 minutes").tag(600)
                    Text("60 minutes").tag(3600)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var advancedTab: some View {
        Form {
            Section("Intelligence") {
                Toggle("AI label suggestions", isOn: $aiLabelSuggestions)
            }

            Section("Developer") {
                Toggle("Show debug menu", isOn: $showDebugMenu)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

import SwiftUI

struct SettingsView: View {
    var accountID: String {
        AccountStore.shared.selectedAccountID ?? AccountStore.shared.accounts.first?.id ?? ""
    }
    @Bindable var appearanceManager: AppearanceManager

    // Use the same @AppStorage keys as AppCoordinator and UndoActionManager
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("undoDuration") private var undoDuration = 5
    @AppStorage("showDebugMenu") private var showDebugMenu = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestions = true
    @AppStorage("syncDirectoryContacts") private var syncDirectoryContacts = false

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
            }

            Section("Google Workspace") {
                Toggle("Sync directory contacts", isOn: $syncDirectoryContacts)
                    .help("Sync contacts from your organization's directory. Requires additional permissions.")
                    .onChange(of: syncDirectoryContacts) { _, enabled in
                        if enabled {
                            Task {
                                do {
                                    try await OAuthService.shared.reauthorize(
                                        accountID: AccountStore.shared.selectedAccountID ?? "",
                                        presentingWindow: NSApp.keyWindow
                                    )
                                } catch {
                                    syncDirectoryContacts = false
                                }
                            }
                        }
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

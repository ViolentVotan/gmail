import SwiftUI

struct SettingsView: View {
    @AppStorage("com.vikingz.vik.selectedAccountID") private var selectedAccountID: String = ""
    @Bindable var appearanceManager: AppearanceManager
    var onReauthorize: ((String, NSWindow?) async throws -> Void)?
    var loadSendAs: ((String) async throws -> [GmailSendAs])?
    var updateSignature: ((String, String, String) async throws -> GmailSendAs)?
    var accounts: [GmailAccount] = []
    var onDeleteDatabase: ((String) -> Void)?
    var onSetAsDefault: ((String) -> Void)?
    var onSetAccentColor: ((String, String) -> Void)?
    var onMoveUp: ((String) -> Void)?
    var onMoveDown: ((String) -> Void)?
    var onReorder: ((IndexSet, Int) -> Void)?

    // Use the same @AppStorage keys as AppCoordinator and UndoActionManager
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("undoDuration") private var undoDuration = 5
    @AppStorage("showDebugMenu") private var showDebugMenu = false
    @AppStorage("aiLabelSuggestions") private var aiLabelSuggestions = true
    @AppStorage("syncDirectoryContacts") private var syncDirectoryContacts = false
    @AppStorage("emailDensity") private var emailDensity = "comfortable"
    @AppStorage("soundEffectsEnabled") private var soundEffectsEnabled = true
    @AppStorage("alwaysLoadRemoteImages") private var alwaysLoadRemoteImages = false

    /// Reactive account ID — reads from UserDefaults via @AppStorage,
    /// falling back to the first connected account.
    private var accountID: String {
        let id = selectedAccountID
        if !id.isEmpty { return id }
        return accounts.first?.id ?? ""
    }

    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.2") {
                AccountsSettingsView(
                    fetchAccounts: { accounts },
                    onSetAsDefault: onSetAsDefault,
                    onSetAccentColor: onSetAccentColor,
                    onMoveUp: onMoveUp,
                    onMoveDown: onMoveDown,
                    onReorder: onReorder
                )
            }

            Tab("General", systemImage: "gearshape") {
                generalTab
            }

            Tab("Signatures", systemImage: "signature") {
                SignaturesSettingsView(
                    accountID: accountID,
                    loadSendAs: { accountID in
                        guard let loadSendAs else { return [] }
                        return try await loadSendAs(accountID)
                    },
                    onUpdateSignature: updateSignature
                )
            }

            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") {
                FiltersSettingsView(accountID: accountID)
            }

            Tab("Advanced", systemImage: "wrench.and.screwdriver") {
                advancedTab
            }
        }
        .frame(minWidth: 480, idealWidth: 480, minHeight: 350, idealHeight: 420)
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

            Section("Display") {
                Picker("Email density", selection: $emailDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable").tag("comfortable")
                    Text("Spacious").tag("spacious")
                }
                .pickerStyle(.segmented)
            }

            Section("Behavior") {
                Toggle("Enable notifications", isOn: $notificationsEnabled)
                Toggle("Sound effects", isOn: $soundEffectsEnabled)

                Picker("Undo duration", selection: $undoDuration) {
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                }
            }

            Section("Privacy") {
                Toggle("Always load remote images", isOn: $alwaysLoadRemoteImages)
                    .help("When enabled, remote images are loaded automatically in all emails. When disabled, you must click \"Load Images\" per email.")
            }

            Section("Google Workspace") {
                Toggle("Sync directory contacts", isOn: $syncDirectoryContacts)
                    .help("Sync contacts from your organization's directory. Requires additional permissions.")
                    .onChange(of: syncDirectoryContacts) { _, enabled in
                        if enabled {
                            Task {
                                do {
                                    try await onReauthorize?(accountID, NSApp.keyWindow)
                                } catch {
                                    syncDirectoryContacts = false
                                    ToastManager.shared.show(message: "Failed to enable contact sync", type: .error)
                                }
                            }
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @State private var showDeleteDatabaseConfirmation = false

    private var advancedTab: some View {
        Form {
            Section("Intelligence") {
                Toggle("AI label suggestions", isOn: $aiLabelSuggestions)
            }

            Section("Developer") {
                Toggle("Show debug menu", isOn: $showDebugMenu)
            }

            Section {
                Button("Delete Local Database", role: .destructive) {
                    showDeleteDatabaseConfirmation = true
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Deletes all cached emails for the current account and triggers a full resync on next launch.")
            }
            .alert("Delete Local Database?", isPresented: $showDeleteDatabaseConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let id = accountID
                    guard !id.isEmpty else { return }
                    onDeleteDatabase?(id)
                }
            } message: {
                Text("This will permanently delete all cached emails for this account. The app will perform a full resync on next launch.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

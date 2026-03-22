import SwiftUI

@main
struct VikApp: App {
    @AppStorage("isSignedIn") private var isSignedIn: Bool = false
    @State private var appearanceManager = AppearanceManager()

    init() {
        UserDefaults.standard.register(defaults: [
            UserDefaultsKey.notificationsEnabled: true,
            UserDefaultsKey.undoDuration: 5,
            UserDefaultsKey.aiLabelSuggestions: true,
            UserDefaultsKey.emailDensity: "comfortable",
            UserDefaultsKey.soundEffectsEnabled: true
        ])
        NotificationService.shared.setup()
        VikShortcuts.updateAppShortcutParameters()
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isSignedIn {
                    ContentView(appearanceManager: appearanceManager)
                        .transition(.opacity)
                } else {
                    OnboardingView(isSignedIn: $isSignedIn)
                        .transition(.opacity)
                }
            }
            .animation(VikAnimation.folderSwitch, value: isSignedIn)
            .task {
                // Start background monitors
                SnoozeMonitor.shared.start()

                // Load snooze/scheduled data for all accounts
                for account in AccountStore.shared.accounts {
                    await SnoozeStore.shared.load(accountID: account.id)
                    await ScheduledSendStore.shared.load(accountID: account.id)
                    await OfflineActionQueue.shared.load(accountID: account.id)
                }

                // Drain any pending offline actions if already online at launch
                OfflineActionQueue.shared.startDraining()

                // Periodically clean up stale temporary files (every 10 minutes)
                Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(600))
                        await TemporaryFileManager.shared.cleanupStale()
                    }
                }

                // Clean up stale files whenever the app resigns active
                for await _ in NotificationCenter.default.notifications(named: NSApplication.willResignActiveNotification) {
                    await TemporaryFileManager.shared.cleanupStale()
                }
            }
        }
        .defaultSize(width: 1200, height: 750)
        .commands {
            // Remove system Edit menu handlers so our hidden buttons can intercept ⌘Z and ⌘A
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .textEditing) {}
            VikCommands()
        }

        Settings {
            SettingsView(
                appearanceManager: appearanceManager,
                onReauthorize: { accountID, window in
                    try await OAuthService.shared.reauthorize(
                        accountID: accountID, presentingWindow: window
                    )
                },
                loadSendAs: { accountID in
                    try await GmailProfileService.shared.listSendAs(accountID: accountID)
                },
                updateSignature: { sendAsEmail, signature, accountID in
                    try await GmailProfileService.shared.updateSignature(
                        sendAsEmail: sendAsEmail, signature: signature, accountID: accountID
                    )
                },
                accounts: AccountStore.shared.accounts,
                onDeleteDatabase: { id in MailDatabase.deleteDatabase(accountID: id) },
                onSetAsDefault: { id in AccountStore.shared.setAsDefault(id: id) },
                onSetAccentColor: { id, hex in AccountStore.shared.setAccentColor(id: id, hex: hex) },
                onMoveUp: { id in AccountStore.shared.moveUp(id: id) },
                onMoveDown: { id in AccountStore.shared.moveDown(id: id) },
                onReorder: { source, destination in AccountStore.shared.reorder(from: source, to: destination) }
            )
        }
    }
}

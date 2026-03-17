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
                    SnoozeStore.shared.load(accountID: account.id)
                    ScheduledSendStore.shared.load(accountID: account.id)
                    OfflineActionQueue.shared.load(accountID: account.id)
                }

                // Drain any pending offline actions if already online at launch
                OfflineActionQueue.shared.startDraining()
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
                }
            )
        }
    }
}

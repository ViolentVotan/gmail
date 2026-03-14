import SwiftUI

@main
struct SerifApp: App {
    @AppStorage("isSignedIn") private var isSignedIn: Bool = false
    @State private var appearanceManager = AppearanceManager()

    init() {
        NotificationService.shared.setup()
        SerifShortcuts.updateAppShortcutParameters()
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
            .animation(.easeInOut(duration: 0.5), value: isSignedIn)
            .task {
                // Start background monitors
                SnoozeMonitor.shared.start()

                // Load snooze/scheduled data for all accounts
                for account in AccountStore.shared.accounts {
                    SnoozeStore.shared.load(accountID: account.id)
                    ScheduledSendStore.shared.load(accountID: account.id)
                    OfflineActionQueue.shared.load(accountID: account.id)
                }
            }
        }
        .defaultSize(width: 1200, height: 750)
        .commands {
            // Remove system Edit menu handlers so our hidden buttons can intercept ⌘Z and ⌘A
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .textEditing) {}
            SerifCommands()
        }

        Settings {
            SettingsView(appearanceManager: appearanceManager)
        }
    }
}

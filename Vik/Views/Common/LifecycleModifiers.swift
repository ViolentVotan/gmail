import SwiftUI

// MARK: - LifecycleStateModifier

/// State-change observers split out to help the type-checker.
struct LifecycleStateModifier: ViewModifier {
    let coordinator: AppCoordinator
    let commandPalette: CommandPaletteViewModel
    @Binding var showSnoozePicker: Bool
    let snoozeCount: Int
    let scheduledCount: Int

    func body(content: Content) -> some View {
        content
            .task {
                commandPalette.buildCommands(coordinator: coordinator)
                await coordinator.handleAppear()
            }
            .onChange(of: coordinator.navigation.selectedFolder) { _, newValue in coordinator.handleFolderChange(newValue) }
            .onChange(of: coordinator.navigation.selectedInboxCategory) { _, newValue in coordinator.handleCategoryChange(newValue) }
            .onChange(of: coordinator.navigation.selectedLabel?.id) { _, _ in coordinator.handleLabelChange() }
            .onChange(of: coordinator.navigation.selectedAccountID) { _, newValue in coordinator.handleAccountChange(newValue) }
            .onChange(of: coordinator.authViewModel.accounts) { oldValue, newValue in coordinator.handleAccountsChange(old: oldValue, new: newValue) }
            .onChange(of: NetworkMonitor.shared.isConnected) { _, connected in
                if connected {
                    OfflineActionQueue.shared.startDraining()
                    Task { await coordinator.sync.syncEngine?.triggerIncrementalSync() }
                    if let calendarEngine = coordinator.calendar.calendarSyncEngine {
                        Task {
                            await CalendarOfflineActionQueue.shared.processQueue(accountID: calendarEngine.accountID)
                            await calendarEngine.triggerSync()
                        }
                    }
                }
            }
            .onChange(of: coordinator.selection.selectedEmail) { oldValue, newValue in
                showSnoozePicker = false
                // Track direction for directional detail pane transitions
                if let newEmail = newValue, let oldEmail = oldValue {
                    if let newIdx = coordinator.selection.emailIndex(for: newEmail.id),
                       let oldIdx = coordinator.selection.emailIndex(for: oldEmail.id) {
                        coordinator.selection.selectionDirection = newIdx < oldIdx ? .top : .bottom
                    }
                }
                coordinator.handleSelectedEmailChange(newValue)
            }
            .onChange(of: coordinator.compose.signatureForNew) { _, _ in if !coordinator.navigation.accountID.isEmpty { coordinator.compose.saveSignatures(for: coordinator.navigation.accountID) } }
            .onChange(of: coordinator.compose.signatureForReply) { _, _ in if !coordinator.navigation.accountID.isEmpty { coordinator.compose.saveSignatures(for: coordinator.navigation.accountID) } }
            .onChange(of: snoozeCount) { _, _ in
                coordinator.refreshSnoozedCacheIfNeeded()
            }
            .onChange(of: scheduledCount) { _, _ in
                coordinator.refreshScheduledCacheIfNeeded()
            }
            .onChange(of: coordinator.mailboxViewModel.lastRestoredMessageID) { _, msgID in
                guard let msgID else { return }
                coordinator.mailboxViewModel.lastRestoredMessageID = nil
                if let restoredEmail = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgID }) {
                    coordinator.selection.selectedEmail = restoredEmail
                    coordinator.selection.selectedEmailIDs = [restoredEmail.id.uuidString]
                }
            }
    }
}

// MARK: - LifecycleNotificationModifier

/// Notification listeners split out to help the type-checker.
struct LifecycleNotificationModifier: ViewModifier {
    let coordinator: AppCoordinator

    func body(content: Content) -> some View {
        content
            .task {
                await withDiscardingTaskGroup { group in
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .composeEmailFromIntent) {
                            let recipient = notification.userInfo?["recipient"] as? String
                            await coordinator.composeNewEmail(recipient: recipient)
                        }
                    }
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .searchEmailFromIntent) {
                            await MainActor.run {
                                coordinator.navigation.selectedFolder = .inbox
                                coordinator.navigation.searchFocusTrigger = true
                            }
                            if let query = notification.userInfo?["query"] as? String, !query.isEmpty {
                                await coordinator.mailboxViewModel.search(query: query)
                            }
                        }
                    }
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .quickReplyFromNotification) {
                            guard let messageId = notification.userInfo?["messageId"] as? String,
                                  let text = notification.userInfo?["text"] as? String,
                                  let accountID = notification.userInfo?["accountID"] as? String,
                                  !text.isEmpty
                            else { continue }
                            await coordinator.handleQuickReply(messageId: messageId, text: text, accountID: accountID)
                        }
                    }
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .openEmailFromIntent) {
                            guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                            let accountID = notification.userInfo?["accountID"] as? String
                            await MainActor.run {
                                if let accountID, !accountID.isEmpty,
                                   coordinator.navigation.selectedAccountID != accountID {
                                    coordinator.navigation.selectedAccountID = accountID
                                }
                                coordinator.navigateToMessage(gmailMessageID: messageId)
                            }
                        }
                    }
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .replyEmailFromIntent) {
                            guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                            let accountID = notification.userInfo?["accountID"] as? String
                            let replyAll = notification.userInfo?["replyAll"] as? Bool ?? false
                            await MainActor.run {
                                if let accountID, !accountID.isEmpty,
                                   coordinator.navigation.selectedAccountID != accountID {
                                    coordinator.navigation.selectedAccountID = accountID
                                }
                                coordinator.navigateAndReply(gmailMessageID: messageId, replyAll: replyAll)
                            }
                        }
                    }
                    group.addTask {
                        for await notification in NotificationCenter.default.notifications(named: .forwardEmailFromIntent) {
                            guard let messageId = notification.userInfo?["messageId"] as? String else { continue }
                            let accountID = notification.userInfo?["accountID"] as? String
                            let recipient = notification.userInfo?["to"] as? String
                            await MainActor.run {
                                if let accountID, !accountID.isEmpty,
                                   coordinator.navigation.selectedAccountID != accountID {
                                    coordinator.navigation.selectedAccountID = accountID
                                }
                                coordinator.navigateAndForward(gmailMessageID: messageId, recipient: recipient)
                            }
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                            await coordinator.sync.syncEngine?.updatePollingInterval(appIsActive: true, windowIsKey: true)
                            await coordinator.calendar.calendarSyncEngine?.updatePollingInterval(
                                calendarActive: coordinator.calendar.viewMode == .calendar,
                                appFocused: true
                            )
                        }
                    }
                    group.addTask {
                        for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                            await coordinator.sync.syncEngine?.updatePollingInterval(appIsActive: false, windowIsKey: false)
                            await coordinator.calendar.calendarSyncEngine?.updatePollingInterval(
                                calendarActive: coordinator.calendar.viewMode == .calendar,
                                appFocused: false
                            )
                        }
                    }
                }
            }
    }
}

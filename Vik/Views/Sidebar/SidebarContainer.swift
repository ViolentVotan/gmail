import SwiftUI

struct SidebarContainer: View {
    let coordinator: AppCoordinator
    @Binding var isSidebarCollapsed: Bool
    var appFocus: FocusState<AppFocus?>.Binding
    let sidebarWidth: CGFloat

    var body: some View {
        @Bindable var navigation = coordinator.navigation
        SidebarView(
            selectedFolder: $navigation.selectedFolder,
            selectedInboxCategory: $navigation.selectedInboxCategory,
            selectedLabel: $navigation.selectedLabel,
            selectedAccountID: $navigation.selectedAccountID,
            authViewModel: coordinator.authViewModel,
            isCollapsed: isSidebarCollapsed,
            userLabels: coordinator.mailboxViewModel.userLabels,
            viewMode: coordinator.calendar.viewMode,
            calendarViewModel: coordinator.calendar.calendarViewModel,
            miniAgendaEvents: coordinator.calendar.miniAgendaEvents,
            onSwitchToMail: { coordinator.switchToMail() },
            onSwitchToCalendar: { coordinator.switchToCalendar() },
            onNavigateToEvent: { event in coordinator.navigateToEvent(event) },
            onRenameLabel: { label, newName in Task { await coordinator.renameLabel(label, to: newName) } },
            onDeleteLabel: { label in Task { await coordinator.deleteLabel(label) } },
            onDropToTrash: { msgId, accountID in
                guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                Task { await coordinator.actionCoordinator.deleteEmail(email, selectNext: { _ in }) }
            },
            onDropToArchive: { msgId, accountID in
                guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                Task { await coordinator.actionCoordinator.archiveEmail(email, selectNext: { _ in }) }
            },
            onDropToSpam: { msgId, accountID in
                guard let email = coordinator.mailboxViewModel.emails.first(where: { $0.gmailMessageID == msgId }) else { return }
                Task { await coordinator.actionCoordinator.markSpamEmail(email, selectNext: { _ in }) }
            },
            onDropToLabel: { msgId, labelId, accountID in
                Task { await coordinator.actionCoordinator.addLabelToEmail(labelId, to: msgId) }
            },
            onSignOut: { account in
                coordinator.authViewModel.signOut(account)
            },
            onSetAsDefault: { id in AccountStore.shared.setAsDefault(id: id) },
            onSetAccentColor: { id, hex in AccountStore.shared.setAccentColor(id: id, hex: hex) },
            onToggleSidebar: {
                withAnimation(VikAnimation.springDefault) {
                    isSidebarCollapsed.toggle()
                }
            },
            onShowDebug: {
                coordinator.panelCoordinator.showDebug = true
            },
            onRefresh: {
                Task { await coordinator.sync.syncEngine?.triggerIncrementalSync() }
            },
            onNewEvent: {
                if let calendarVM = coordinator.calendar.calendarViewModel {
                    calendarVM.selectedDate = Date()
                }
                coordinator.switchToCalendar()
            }
        )
        .focused(appFocus, equals: .sidebar)
        .frame(width: sidebarWidth)
        .background(.regularMaterial)
    }
}

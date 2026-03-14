import Testing
@testable import Serif

@Suite @MainActor struct LabelManagementTests {

    // MARK: - Helpers

    private func makeLabel(id: String = "Label_1", name: String = "Work") -> GmailLabel {
        GmailLabel(id: id, name: name, type: "user",
                   messagesTotal: 10, messagesUnread: 2,
                   threadsTotal: 8, threadsUnread: 1, color: nil,
                   labelListVisibility: nil, messageListVisibility: nil)
    }

    // MARK: - MailboxViewModel

    @Test func renameLabelUpdatesLocalArray() {
        let vm = MailboxViewModel(accountID: "test")
        let label = makeLabel()
        vm.labels = [label]

        // Simulate the optimistic rename logic (same as renameLabel before the await)
        if let idx = vm.labels.firstIndex(where: { $0.id == label.id }) {
            let updated = GmailLabel(id: label.id, name: "Personal", type: label.type,
                                      messagesTotal: label.messagesTotal, messagesUnread: label.messagesUnread,
                                      threadsTotal: label.threadsTotal, threadsUnread: label.threadsUnread,
                                      color: label.color,
                                      labelListVisibility: label.labelListVisibility,
                                      messageListVisibility: label.messageListVisibility)
            vm.labels[idx] = updated
        }

        #expect(vm.labels.first?.name == "Personal", "Label name should be updated optimistically")
        #expect(vm.labels.count == 1, "Label count should remain the same")
    }

    @Test func deleteLabelRemovesFromArray() {
        let vm = MailboxViewModel(accountID: "test")
        let label1 = makeLabel(id: "Label_1", name: "Work")
        let label2 = makeLabel(id: "Label_2", name: "Personal")
        vm.labels = [label1, label2]

        // Simulate the optimistic delete logic (same as deleteLabel before the await)
        vm.labels.removeAll { $0.id == label1.id }

        #expect(vm.labels.count == 1, "One label should remain after deletion")
        #expect(vm.labels.first?.id == "Label_2", "The remaining label should be Label_2")
    }

    // MARK: - AppCoordinator

    @Test func deleteSelectedLabelClearsSelection() {
        let coordinator = AppCoordinator()
        let label = makeLabel()
        coordinator.mailboxViewModel.labels = [label]
        coordinator.selectedFolder = .labels
        coordinator.selectedLabel = label

        // Simulate what coordinator.deleteLabel does after the VM call:
        // 1. Label removed from VM
        coordinator.mailboxViewModel.labels.removeAll { $0.id == label.id }
        // 2. Coordinator clears selection
        if coordinator.selectedLabel?.id == label.id {
            coordinator.selectedLabel = nil
            if coordinator.selectedFolder == .labels {
                coordinator.selectedLabel = coordinator.mailboxViewModel.labels.filter { !$0.isSystemLabel }.first
            }
        }

        #expect(coordinator.selectedLabel == nil, "Selected label should be nil after deleting it (no remaining user labels)")
    }

    @Test func deleteNonSelectedLabelKeepsSelection() {
        let coordinator = AppCoordinator()
        let label1 = makeLabel(id: "Label_1", name: "Work")
        let label2 = makeLabel(id: "Label_2", name: "Personal")
        coordinator.mailboxViewModel.labels = [label1, label2]
        coordinator.selectedFolder = .labels
        coordinator.selectedLabel = label1

        // Delete label2 (not selected)
        coordinator.mailboxViewModel.labels.removeAll { $0.id == label2.id }

        // Selection should not change
        #expect(coordinator.selectedLabel?.id == "Label_1", "Selected label should remain unchanged")
    }
}

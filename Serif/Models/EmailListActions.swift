import SwiftUI

struct EmailListActions {
    // MARK: - Per-email actions

    var onArchive: ((Email) -> Void)?
    var onDelete: ((Email) -> Void)?
    var onToggleStar: ((Email) -> Void)?
    var onMarkUnread: ((Email) -> Void)?
    var onMarkSpam: ((Email) -> Void)?
    var onUnsubscribe: ((Email) -> Void)?
    var onMoveToInbox: ((Email) -> Void)?
    var onDeletePermanently: ((Email) -> Void)?
    var onMarkNotSpam: ((Email) -> Void)?
    var onSnooze: ((Email, Date) -> Void)?
    var onReply: ((Email) -> Void)?
    var onReplyAll: ((Email) -> Void)?
    var onForward: ((Email) -> Void)?

    // MARK: - Bulk actions

    var onBulkArchive: (() -> Void)?
    var onBulkDelete: (() -> Void)?
    var onBulkMarkUnread: (() -> Void)?
    var onBulkMarkRead: (() -> Void)?
    var onBulkToggleStar: (() -> Void)?

    // MARK: - Folder actions

    var onEmptyTrash: (() -> Void)?
    var onEmptySpam: (() -> Void)?

    // MARK: - Data loading

    var onLoadMore: () -> Void = {}
    var onSearch: (String) -> Void = { _ in }
    var onRefresh: (() async -> Void)?
}

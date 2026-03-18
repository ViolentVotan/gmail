import SwiftUI

private struct ContactPopoverModifier: ViewModifier {
    let contact: Contact
    let message: GmailMessage?
    let accountID: String
    let composeTo: @MainActor (String) -> Void
    let searchSender: @MainActor (String) -> Void

    @State private var viewModel: ContactPopoverViewModel?

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                viewModel = ContactPopoverViewModel(
                    contact: contact,
                    message: message,
                    accountID: accountID,
                    composeTo: composeTo,
                    searchSender: searchSender
                )
            }
            .pointerStyle(.link)
            .popover(item: $viewModel, arrowEdge: .bottom) { vm in
                ContactPopoverView(viewModel: vm)
            }
    }
}

extension View {
    func contactPopover(
        contact: Contact,
        message: GmailMessage? = nil,
        accountID: String,
        composeTo: @escaping @MainActor (String) -> Void,
        searchSender: @escaping @MainActor (String) -> Void
    ) -> some View {
        modifier(ContactPopoverModifier(
            contact: contact,
            message: message,
            accountID: accountID,
            composeTo: composeTo,
            searchSender: searchSender
        ))
    }
}

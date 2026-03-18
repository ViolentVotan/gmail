import SwiftUI

private struct ContactPopoverModifier: ViewModifier {
    let contact: Contact
    let message: GmailMessage?
    let accountID: String
    let composeTo: @MainActor (String) -> Void
    let searchSender: @MainActor (String) -> Void

    @State private var showPopover = false
    @State private var viewModel: ContactPopoverViewModel?

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                if viewModel == nil {
                    viewModel = ContactPopoverViewModel(
                        contact: contact,
                        message: message,
                        accountID: accountID,
                        composeTo: composeTo,
                        searchSender: searchSender
                    )
                }
                showPopover = true
            }
            .pointerStyle(.link)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                if let viewModel {
                    ContactPopoverView(viewModel: viewModel)
                }
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
